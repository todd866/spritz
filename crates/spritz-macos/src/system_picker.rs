use crate::cf::{
    cfnumber_to_i64, cfstr, kCFAllocatorDefault, CFNumberCreate, CFPreferencesAppSynchronize,
    CFPreferencesCopyAppValue, CFPreferencesSetAppValue, CFRef, K_CF_NUMBER_SINT32_TYPE,
};
use std::ffi::{c_char, c_void, CString};
use std::ptr;

type SetSymbolicHotKeyFn = extern "C" fn(i32, u8) -> i32;
type IsSymbolicHotKeyFn = extern "C" fn(i32) -> u8;

const CHAR_PALETTE_HOTKEY_ID: i32 = 50;
const HI_TOOLBOX_DOMAIN: &str = "com.apple.HIToolbox";
const FN_USAGE_KEY: &str = "AppleFnUsageType";
const FN_USAGE_NONE: i32 = 0;

// Carbon constants verified from HIToolbox/Events.h and CarbonEvents.h
const K_VK_SPACE: u32 = 0x31;
const CMD_KEY: u32 = 1 << 8;
const CONTROL_KEY: u32 = 1 << 12;
const K_EVENT_CLASS_KEYBOARD: u32 = u32::from_be_bytes(*b"keyb");
const K_EVENT_HOT_KEY_PRESSED: u32 = 5;
const HOTKEY_SIGNATURE: u32 = u32::from_be_bytes(*b"SPRZ");

#[repr(C)]
#[derive(Clone, Copy)]
struct EventTypeSpec {
    event_class: u32,
    event_kind: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct EventHotKeyID {
    signature: u32,
    id: u32,
}

type EventHandlerRef = *mut c_void;
type EventHotKeyRef = *mut c_void;
type EventHandlerCallRef = *mut c_void;
type EventRef = *mut c_void;

#[link(name = "Carbon", kind = "framework")]
extern "C" {
    fn GetApplicationEventTarget() -> *mut c_void;
    fn InstallEventHandler(
        in_target: *mut c_void,
        in_handler: extern "C" fn(EventHandlerCallRef, EventRef, *mut c_void) -> i32,
        in_num_types: usize,
        in_list: *const EventTypeSpec,
        in_user_data: *mut c_void,
        out_ref: *mut EventHandlerRef,
    ) -> i32;
    fn RemoveEventHandler(in_handler_ref: EventHandlerRef) -> i32;
    fn RegisterEventHotKey(
        in_hotkey_code: u32,
        in_hotkey_modifiers: u32,
        in_hotkey_id: EventHotKeyID,
        in_target: *mut c_void,
        in_options: u32,
        out_ref: *mut EventHotKeyRef,
    ) -> i32;
    fn UnregisterEventHotKey(in_hotkey: EventHotKeyRef) -> i32;
}

fn resolve_cgs_symbol<T>(name: &str) -> Option<T> {
    let cname = CString::new(name).ok()?;
    unsafe {
        let sym = libc::dlsym(libc::RTLD_DEFAULT, cname.as_ptr() as *const c_char);
        if sym.is_null() {
            None
        } else {
            Some(std::mem::transmute_copy(&sym))
        }
    }
}

pub fn cgs_character_palette_enabled() -> bool {
    if let Some(f) = resolve_cgs_symbol::<IsSymbolicHotKeyFn>("CGSIsSymbolicHotKeyEnabled") {
        f(CHAR_PALETTE_HOTKEY_ID) != 0
    } else {
        true
    }
}

pub fn set_cgs_character_palette_enabled(enabled: bool) -> bool {
    if let Some(f) = resolve_cgs_symbol::<SetSymbolicHotKeyFn>("CGSSetSymbolicHotKeyEnabled") {
        f(CHAR_PALETTE_HOTKEY_ID, if enabled { 1 } else { 0 }) == 0
    } else {
        false
    }
}

pub fn current_fn_usage_type() -> i32 {
    let key = cfstr(FN_USAGE_KEY);
    let domain = cfstr(HI_TOOLBOX_DOMAIN);
    unsafe {
        let raw = CFPreferencesCopyAppValue(key.as_ptr(), domain.as_ptr());
        let Some(cf_ref) = CFRef::from_owned(raw) else {
            return 0;
        };
        cfnumber_to_i64(cf_ref.as_ptr()).unwrap_or(0) as i32
    }
}

pub fn set_fn_usage_type(val: i32) {
    let key = cfstr(FN_USAGE_KEY);
    let domain = cfstr(HI_TOOLBOX_DOMAIN);
    unsafe {
        if let Some(num) = CFRef::from_owned(CFNumberCreate(
            kCFAllocatorDefault,
            K_CF_NUMBER_SINT32_TYPE,
            &val as *const i32 as *const c_void,
        )) {
            CFPreferencesSetAppValue(key.as_ptr(), num.as_ptr(), domain.as_ptr());
            CFPreferencesAppSynchronize(domain.as_ptr());
        }
    }
}

pub fn take_over_globe_key(prior_saved: &mut Option<i32>) -> bool {
    let current = current_fn_usage_type();
    if prior_saved.is_none() {
        *prior_saved = Some(current);
    }
    if current != FN_USAGE_NONE {
        set_fn_usage_type(FN_USAGE_NONE);
        true // needs logout to fully apply
    } else {
        false
    }
}

pub fn restore_globe_key(prior_saved: &mut Option<i32>) {
    if let Some(prior) = prior_saved.take() {
        set_fn_usage_type(prior);
    }
}

pub struct CarbonToggleHotkey {
    handler_ref: EventHandlerRef,
    hotkey_ref: EventHotKeyRef,
    cookie: *mut HotkeyCookie,
}

struct HotkeyCookie {
    on_toggle: extern "C" fn(*mut c_void),
    ctx: *mut c_void,
}

extern "C" fn hotkey_handler(
    _call_ref: EventHandlerCallRef,
    _event: EventRef,
    user_data: *mut c_void,
) -> i32 {
    if !user_data.is_null() {
        unsafe {
            let cookie = &*(user_data as *const HotkeyCookie);
            (cookie.on_toggle)(cookie.ctx);
        }
    }
    0
}

impl CarbonToggleHotkey {
    pub fn register_ctrl_cmd_space(
        on_toggle: extern "C" fn(*mut c_void),
        ctx: *mut c_void,
    ) -> Option<Self> {
        let cookie = Box::into_raw(Box::new(HotkeyCookie { on_toggle, ctx }));
        let spec = EventTypeSpec {
            event_class: K_EVENT_CLASS_KEYBOARD,
            event_kind: K_EVENT_HOT_KEY_PRESSED,
        };
        let mut handler_ref: EventHandlerRef = ptr::null_mut();
        let mut hotkey_ref: EventHotKeyRef = ptr::null_mut();
        unsafe {
            let target = GetApplicationEventTarget();
            if InstallEventHandler(
                target,
                hotkey_handler,
                1,
                &spec,
                cookie as *mut c_void,
                &mut handler_ref,
            ) != 0
            {
                drop(Box::from_raw(cookie));
                return None;
            }
            let hk_id = EventHotKeyID {
                signature: HOTKEY_SIGNATURE,
                id: 1,
            };
            if RegisterEventHotKey(
                K_VK_SPACE,
                CMD_KEY | CONTROL_KEY,
                hk_id,
                target,
                0,
                &mut hotkey_ref,
            ) != 0
            {
                RemoveEventHandler(handler_ref);
                drop(Box::from_raw(cookie));
                return None;
            }
            Some(Self {
                handler_ref,
                hotkey_ref,
                cookie,
            })
        }
    }
}

impl Drop for CarbonToggleHotkey {
    fn drop(&mut self) {
        unsafe {
            if !self.hotkey_ref.is_null() {
                UnregisterEventHotKey(self.hotkey_ref);
            }
            if !self.handler_ref.is_null() {
                RemoveEventHandler(self.handler_ref);
            }
            drop(Box::from_raw(self.cookie));
        }
    }
}
