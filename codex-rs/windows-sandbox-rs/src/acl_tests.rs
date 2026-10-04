use super::acl_api_result;
use super::deny_ace_already_present;
use super::ensure_handle_is_not_filesystem_root;
use crate::token::LocalSid;
use pretty_assertions::assert_eq;
use std::fs::OpenOptions;
use std::os::windows::fs::OpenOptionsExt;
use windows_sys::Win32::Foundation::ERROR_ACCESS_DENIED;
use windows_sys::Win32::Foundation::HLOCAL;
use windows_sys::Win32::Foundation::LocalFree;
use windows_sys::Win32::Security::Authorization::ConvertStringSecurityDescriptorToSecurityDescriptorW;
use windows_sys::Win32::Security::Authorization::SDDL_REVISION_1;
use windows_sys::Win32::Security::DACL_SECURITY_INFORMATION;
use windows_sys::Win32::Security::GetSecurityDescriptorControl;
use windows_sys::Win32::Security::SE_DACL_PROTECTED;
use windows_sys::Win32::Security::SetFileSecurityW;
use windows_sys::Win32::Security::UNPROTECTED_DACL_SECURITY_INFORMATION;
use windows_sys::Win32::Storage::FileSystem::FILE_FLAG_BACKUP_SEMANTICS;
use windows_sys::Win32::Storage::FileSystem::READ_CONTROL;

#[test]
fn deny_ace_update_failure_is_an_error() {
    let path = std::path::Path::new(r"C:\world-writable");
    let error = acl_api_result(path, "SetNamedSecurityInfoW", ERROR_ACCESS_DENIED)
        .expect_err("access denied must not look like an already-present ACE");

    assert_eq!(
        error.to_string(),
        r"SetNamedSecurityInfoW failed for C:\world-writable: 5"
    );
}

#[test]
fn deny_read_root_check_uses_the_open_handle() {
    let cwd = std::env::current_dir().expect("current directory");
    let root = cwd.ancestors().last().expect("filesystem root");
    let root_directory = OpenOptions::new()
        .access_mode(READ_CONTROL)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
        .open(root)
        .expect("open filesystem root");
    let diagnostic_path = std::path::Path::new(r"C:\not-a-root");

    let error = ensure_handle_is_not_filesystem_root(&root_directory, diagnostic_path)
        .expect_err("classification must follow the root handle, not the diagnostic path");

    assert_eq!(
        error.to_string(),
        r"refusing to apply a deny-read ACE to filesystem root C:\not-a-root"
    );
}

#[test]
fn existing_deny_ace_is_visible_without_write_dac() {
    let target = tempfile::NamedTempFile::new().expect("temporary file");
    let sid = LocalSid::from_string("S-1-5-21-10-20-30-40").expect("test SID");
    let path = target.path();
    let psid = sid.as_ptr();
    assert!(unsafe { super::add_deny_read_ace(path, psid) }.expect("add deny ACE"));
    let already_present =
        unsafe { deny_ace_already_present(target.as_file(), path, psid, super::DenyAceKind::Read) }
            .expect("read existing deny ACE");
    assert!(already_present);
}

#[test]
fn batched_write_denies_cover_every_missing_sid_and_children() {
    let parent = tempfile::tempdir().expect("parent directory");
    let child = parent.path().join("child.txt");
    std::fs::write(&child, b"x").expect("child file");
    let existing = LocalSid::from_string("S-1-5-21-10-20-30-50").expect("existing SID");
    let first_new = LocalSid::from_string("S-1-5-21-10-20-30-51").expect("first new SID");
    let second_new = LocalSid::from_string("S-1-5-21-10-20-30-52").expect("second new SID");
    let all = [existing.as_ptr(), first_new.as_ptr(), second_new.as_ptr()];

    unsafe {
        assert!(super::add_deny_write_ace(parent.path(), existing.as_ptr()).expect("seed deny"));
        assert!(super::add_deny_write_aces(parent.path(), &all).expect("batched deny"));
        assert!(!super::add_deny_write_aces(parent.path(), &all).expect("repeat batched deny"));

        let (dacl, descriptor) = super::fetch_dacl_handle(parent.path()).expect("parent DACL");
        let explicit_denies: Vec<bool> = all
            .iter()
            .map(|sid| super::dacl_has_write_deny_for_sid(dacl, *sid))
            .collect();
        LocalFree(descriptor as HLOCAL);
        assert_eq!(explicit_denies, vec![true, true, true]);

        let (child_dacl, child_descriptor) = super::fetch_dacl_handle(&child).expect("child DACL");
        let inherited_denies: Vec<bool> = all
            .iter()
            .map(|sid| super::dacl_has_write_deny_for_sid(child_dacl, *sid))
            .collect();
        LocalFree(child_descriptor as HLOCAL);
        assert_eq!(inherited_denies, vec![true, true, true]);
    }
}

#[test]
fn revoking_absent_sid_preserves_child_null_dacl() {
    let parent = tempfile::tempdir().expect("parent directory");
    let child = parent.path().join("child");
    std::fs::create_dir(&child).expect("child directory");
    let sid = LocalSid::from_string("S-1-5-21-10-20-30-40").expect("absent SID");
    let other_sid = LocalSid::from_string("S-1-5-21-10-20-30-41").expect("inherited SID");

    unsafe {
        super::add_allow_ace(parent.path(), other_sid.as_ptr()).expect("inheritable parent ACE");
        let mut descriptor = std::ptr::null_mut();
        assert_ne!(
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                crate::winutil::to_wide("D:NO_ACCESS_CONTROL").as_ptr(),
                SDDL_REVISION_1,
                &mut descriptor,
                std::ptr::null_mut(),
            ),
            0,
        );
        // The legacy setter preserves a null DACL without applying automatic inheritance.
        let set = SetFileSecurityW(
            crate::winutil::to_wide(&child).as_ptr(),
            DACL_SECURITY_INFORMATION | UNPROTECTED_DACL_SECURITY_INFORMATION,
            descriptor,
        );
        LocalFree(descriptor as HLOCAL);
        assert_ne!(set, 0, "set an unprotected null DACL");
        for revoke in [false, true] {
            if revoke {
                super::revoke_ace(parent.path(), sid.as_ptr()).expect("revoke absent SID");
            }
            let (dacl, descriptor) = super::fetch_dacl_handle(&child).expect("child permissions");
            let mut control = 0;
            let mut revision = 0;
            let valid = GetSecurityDescriptorControl(descriptor, &mut control, &mut revision);
            LocalFree(descriptor as HLOCAL);

            assert_ne!(valid, 0, "read child inheritance flags");
            assert_eq!(control & SE_DACL_PROTECTED, 0, "child permits inheritance");
            assert!(
                dacl.is_null(),
                "revocation must preserve the child's null DACL"
            );
        }
    }
}
