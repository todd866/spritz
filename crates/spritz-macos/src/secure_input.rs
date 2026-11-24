use crate::cf::{cfnumber_to_i64, cfstr, CFArrayGetCount, CFArrayGetTypeID, CFArrayGetValueAtIndex, CFDictionaryGetTypeID, CFDictionaryGetValue, CFGetTypeID, CFRef, CFTypeRef};

#[link(name = "Carbon", kind = "framework")]
extern "C" {
    fn IsSecureEventInputEnabled() -> u8;
}

#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IORegistryGetRootEntry(main_port: u32) -> u32;
    fn IORegistryEntryCreateCFProperty(
        entry: u32,
        key: CFTypeRef,
        allocator: CFTypeRef,
        options: u32,
    ) -> CFTypeRef;
    fn IOObjectRelease(object: u32) -> i32;
}

pub fn is_secure_event_input_enabled() -> bool {
    unsafe { IsSecureEventInputEnabled() != 0 }
}

/// Returns the PID currently holding `EnableSecureEventInput()`, if exposed in IOKit.
pub fn secure_input_holder_pid() -> Option<i32> {
    if !is_secure_event_input_enabled() {
        return None;
    }
    unsafe {
        let root = IORegistryGetRootEntry(0);
        if root == 0 {
            return None;
        }
        let key_users = cfstr("IOConsoleUsers");
        let prop = IORegistryEntryCreateCFProperty(root, key_users.as_ptr(), std::ptr::null(), 0);
        IOObjectRelease(root);
        let Some(users_ref) = CFRef::from_owned(prop) else {
            return None;
        };
        if CFGetTypeID(users_ref.as_ptr()) != CFArrayGetTypeID() {
            return None;
        }
        let key_pid = cfstr("kCGSSessionSecureInputPID");
        let n = CFArrayGetCount(users_ref.as_ptr());
        for i in 0..n {
            let item = CFArrayGetValueAtIndex(users_ref.as_ptr(), i);
            if item.is_null() || CFGetTypeID(item) != CFDictionaryGetTypeID() {
                continue;
            }
            let pid_val = CFDictionaryGetValue(item, key_pid.as_ptr());
            if let Some(pid) = cfnumber_to_i64(pid_val) {
                if pid > 0 {
                    return Some(pid as i32);
                }
            }
        }
        None
    }
}
