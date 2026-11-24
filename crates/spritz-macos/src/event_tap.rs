use crate::cf::{
    kCFAllocatorDefault, kCFRunLoopCommonModes, monotonic_uptime_secs, CFRef, CFRunLoopAddSource,
    CFRunLoopGetMain, CFRunLoopRemoveSource, CFRunLoopSourceRef, CFTypeRef, MainTimer,
};
use crate::inserter::SYNTH_MARKER;
use spritz_core::fn_gesture::{FnAction, FnGesture};
use std::ffi::c_void;
use std::ptr;

pub type CGEventTapProxy = *mut c_void;
pub type CGEventRef = *mut c_void;
pub type CGEventMask = u64;
pub type CGEventType = u32;

pub const K_CG_SESSION_EVENT_TAP: u32 = 1;
pub const K_CG_HEAD_INSERT_EVENT_TAP: u32 = 0;
pub const K_CG_EVENT_TAP_OPTION_DEFAULT: u32 = 0;

pub const K_CG_EVENT_KEY_DOWN: CGEventType = 10;
pub const K_CG_EVENT_FLAGS_CHANGED: CGEventType = 12;
pub const K_CG_EVENT_TAP_DISABLED_BY_TIMEOUT: CGEventType = 0xFFFF_FFFE;
pub const K_CG_EVENT_TAP_DISABLED_BY_USER_INPUT: CGEventType = 0xFFFF_FFFF;

pub const K_CG_EVENT_FLAG_MASK_SHIFT: u64 = 0x0002_0000;
pub const K_CG_EVENT_FLAG_MASK_CONTROL: u64 = 0x0004_0000;
pub const K_CG_EVENT_FLAG_MASK_ALTERNATE: u64 = 0x0008_0000;
pub const K_CG_EVENT_FLAG_MASK_COMMAND: u64 = 0x0010_0000;
pub const K_CG_EVENT_FLAG_MASK_SECONDARY_FN: u64 = 0x0080_0000;

const K_CG_KEYBOARD_EVENT_KEYCODE: u32 = 9;
const K_CG_EVENT_SOURCE_USER_DATA: u32 = 42;

const K_VK_RETURN: i64 = 0x24;
const K_VK_TAB: i64 = 0x30;
const K_VK_DELETE: i64 = 0x33;
const K_VK_ESCAPE: i64 = 0x35;
const K_VK_FUNCTION: i64 = 0x3F;
const K_VK_ANSI_KEYPAD_ENTER: i64 = 0x4C;
const K_VK_FORWARD_DELETE: i64 = 0x75;
const K_VK_LEFT_ARROW: i64 = 0x7B;
const K_VK_RIGHT_ARROW: i64 = 0x7C;
const K_VK_DOWN_ARROW: i64 = 0x7D;
const K_VK_UP_ARROW: i64 = 0x7E;

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGPreflightListenEventAccess() -> bool;
    fn CGEventTapCreate(
        tap: u32,
        place: u32,
        options: u32,
        events_of_interest: CGEventMask,
        callback: extern "C" fn(CGEventTapProxy, CGEventType, CGEventRef, *mut c_void) -> CGEventRef,
        user_info: *mut c_void,
    ) -> CFTypeRef;
    fn CGEventTapEnable(tap: CFTypeRef, enable: bool);
    fn CGEventGetFlags(event: CGEventRef) -> u64;
    fn CGEventGetIntegerValueField(event: CGEventRef, field: u32) -> i64;
    fn CGEventKeyboardGetUnicodeString(
        event: CGEventRef,
        max_string_length: usize,
        actual_string_length: *mut usize,
        unicode_string: *mut u16,
    );
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFMachPortCreateRunLoopSource(
        allocator: *const c_void,
        port: CFTypeRef,
        order: isize,
    ) -> CFRunLoopSourceRef;
    fn CFMachPortInvalidate(port: CFTypeRef);
}

pub fn has_input_monitoring_permission() -> bool {
    unsafe { CGPreflightListenEventAccess() }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyInput {
    Escape,
    Return { shift: bool },
    Tab { shift: bool },
    ArrowUp,
    ArrowDown,
    ArrowLeft,
    ArrowRight,
    Backspace,
    Char(char),
}

pub fn translate_cgevent(event: CGEventRef) -> Option<KeyInput> {
    if event.is_null() {
        return None;
    }
    unsafe {
        let keycode = CGEventGetIntegerValueField(event, K_CG_KEYBOARD_EVENT_KEYCODE);
        let flags = CGEventGetFlags(event);
        if (flags & (K_CG_EVENT_FLAG_MASK_COMMAND | K_CG_EVENT_FLAG_MASK_CONTROL | K_CG_EVENT_FLAG_MASK_ALTERNATE)) != 0 {
            return None;
        }
        let shift = (flags & K_CG_EVENT_FLAG_MASK_SHIFT) != 0;
        match keycode {
            K_VK_ESCAPE => return Some(KeyInput::Escape),
            K_VK_RETURN | K_VK_ANSI_KEYPAD_ENTER => return Some(KeyInput::Return { shift }),
            K_VK_TAB => return Some(KeyInput::Tab { shift }),
            K_VK_UP_ARROW => return Some(KeyInput::ArrowUp),
            K_VK_DOWN_ARROW => return Some(KeyInput::ArrowDown),
            K_VK_LEFT_ARROW => return Some(KeyInput::ArrowLeft),
            K_VK_RIGHT_ARROW => return Some(KeyInput::ArrowRight),
            K_VK_DELETE | K_VK_FORWARD_DELETE => return Some(KeyInput::Backspace),
            _ => {}
        }

        let mut actual_len: usize = 0;
        let mut buf = [0u16; 8];
        CGEventKeyboardGetUnicodeString(event, buf.len(), &mut actual_len, buf.as_mut_ptr());
        if actual_len == 0 {
            return None;
        }
        let s = String::from_utf16(&buf[..actual_len.min(buf.len())]).ok()?;
        let ch = s.chars().next()?;
        Some(KeyInput::Char(ch))
    }
}

pub fn is_speech_cycle_event(event: CGEventRef) -> Option<bool> {
    if event.is_null() {
        return None;
    }
    unsafe {
        let keycode = CGEventGetIntegerValueField(event, K_CG_KEYBOARD_EVENT_KEYCODE);
        let flags = CGEventGetFlags(event);
        if keycode == K_VK_TAB
            && (flags & K_CG_EVENT_FLAG_MASK_SECONDARY_FN) != 0
            && (flags & (K_CG_EVENT_FLAG_MASK_COMMAND | K_CG_EVENT_FLAG_MASK_CONTROL | K_CG_EVENT_FLAG_MASK_ALTERNATE)) == 0
        {
            Some((flags & K_CG_EVENT_FLAG_MASK_SHIFT) != 0)
        } else {
            None
        }
    }
}

pub trait EventTapSink: 'static {
    fn on_fn_action(&mut self, action: FnAction);
    fn on_speech_cycle(&mut self, backward: bool) -> bool;
    fn on_key_input(&mut self, input: KeyInput) -> bool;
    fn on_tap_lost(&mut self);
}

struct TapCookie<S: EventTapSink> {
    sink_ptr: *mut S,
    tap: Option<CFRef>,
    source: Option<CFRef>,
    fn_gesture: FnGesture,
    fn_timer: Option<MainTimer>,
}

pub struct EventTap<S: EventTapSink> {
    cookie: *mut TapCookie<S>,
}

impl<S: EventTapSink> EventTap<S> {
    pub fn start(sink: *mut S) -> Option<Self> {
        let mask: CGEventMask = (1u64 << K_CG_EVENT_KEY_DOWN) | (1u64 << K_CG_EVENT_FLAGS_CHANGED);
        let cookie = Box::into_raw(Box::new(TapCookie {
            sink_ptr: sink,
            tap: None,
            source: None,
            fn_gesture: FnGesture::default(),
            fn_timer: None,
        }));

        extern "C" fn callback<S: EventTapSink>(
            _proxy: CGEventTapProxy,
            event_type: CGEventType,
            event: CGEventRef,
            user_info: *mut c_void,
        ) -> CGEventRef {
            if user_info.is_null() || event.is_null() {
                return event;
            }
            unsafe {
                let cookie = &mut *(user_info as *mut TapCookie<S>);
                if CGEventGetIntegerValueField(event, K_CG_EVENT_SOURCE_USER_DATA) == SYNTH_MARKER {
                    return event;
                }
                if event_type == K_CG_EVENT_TAP_DISABLED_BY_TIMEOUT
                    || event_type == K_CG_EVENT_TAP_DISABLED_BY_USER_INPUT
                {
                    cookie.fn_timer = None;
                    if let Some(act) = cookie.fn_gesture.reset() {
                        (*cookie.sink_ptr).on_fn_action(act);
                    }
                    if let Some(tap) = &cookie.tap {
                        CGEventTapEnable(tap.as_ptr(), true);
                    }
                    (*cookie.sink_ptr).on_tap_lost();
                    return event;
                }
                if event_type == K_CG_EVENT_FLAGS_CHANGED {
                    handle_flags_changed(cookie, event);
                    return event;
                }
                if event_type != K_CG_EVENT_KEY_DOWN {
                    return event;
                }

                cookie.fn_timer = None;
                if let Some(act) = cookie.fn_gesture.interrupt() {
                    (*cookie.sink_ptr).on_fn_action(act);
                }

                if let Some(backward) = is_speech_cycle_event(event) {
                    if (*cookie.sink_ptr).on_speech_cycle(backward) {
                        return ptr::null_mut();
                    }
                }

                if let Some(input) = translate_cgevent(event) {
                    if (*cookie.sink_ptr).on_key_input(input) {
                        return ptr::null_mut();
                    }
                }
                event
            }
        }

        unsafe {
            let raw_tap = CGEventTapCreate(
                K_CG_SESSION_EVENT_TAP,
                K_CG_HEAD_INSERT_EVENT_TAP,
                K_CG_EVENT_TAP_OPTION_DEFAULT,
                mask,
                callback::<S>,
                cookie as *mut c_void,
            );
            let Some(tap) = CFRef::from_owned(raw_tap) else {
                drop(Box::from_raw(cookie));
                return None;
            };
            let raw_src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap.as_ptr(), 0);
            let Some(source) = CFRef::from_owned(raw_src) else {
                CFMachPortInvalidate(tap.as_ptr());
                drop(Box::from_raw(cookie));
                return None;
            };
            CFRunLoopAddSource(CFRunLoopGetMain(), source.as_ptr(), kCFRunLoopCommonModes);
            CGEventTapEnable(tap.as_ptr(), true);
            (*cookie).tap = Some(tap);
            (*cookie).source = Some(source);
            Some(Self { cookie })
        }
    }
}

unsafe fn handle_flags_changed<S: EventTapSink>(cookie: &mut TapCookie<S>, event: CGEventRef) {
    let keycode = CGEventGetIntegerValueField(event, K_CG_KEYBOARD_EVENT_KEYCODE);
    if keycode != K_VK_FUNCTION {
        cookie.fn_timer = None;
        if let Some(act) = cookie.fn_gesture.interrupt() {
            (*cookie.sink_ptr).on_fn_action(act);
        }
        return;
    }

    let flags = CGEventGetFlags(event);
    let now = monotonic_uptime_secs();
    if (flags & K_CG_EVENT_FLAG_MASK_SECONDARY_FN) != 0 {
        if cookie.fn_gesture.state != spritz_core::fn_gesture::FnState::Idle {
            return;
        }
        let modified = (flags
            & (K_CG_EVENT_FLAG_MASK_COMMAND
                | K_CG_EVENT_FLAG_MASK_CONTROL
                | K_CG_EVENT_FLAG_MASK_ALTERNATE
                | K_CG_EVENT_FLAG_MASK_SHIFT))
            != 0;
        cookie.fn_gesture.press(now, modified);
        let cookie_addr = cookie as *mut TapCookie<S> as usize;
        cookie.fn_timer = MainTimer::after_secs(FnGesture::HOLD_DELAY_SECS, move || {
            let c = &mut *(cookie_addr as *mut TapCookie<S>);
            if let Some(act) = c.fn_gesture.advance(monotonic_uptime_secs()) {
                (*c.sink_ptr).on_fn_action(act);
            }
        });
    } else {
        cookie.fn_timer = None;
        if let Some(act) = cookie.fn_gesture.release(now) {
            (*cookie.sink_ptr).on_fn_action(act);
        }
    }
}

impl<S: EventTapSink> Drop for EventTap<S> {
    fn drop(&mut self) {
        unsafe {
            let mut cookie = Box::from_raw(self.cookie);
            cookie.fn_timer = None;
            if let Some(tap) = &cookie.tap {
                CGEventTapEnable(tap.as_ptr(), false);
                CFMachPortInvalidate(tap.as_ptr());
            }
            if let Some(src) = &cookie.source {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src.as_ptr(), kCFRunLoopCommonModes);
            }
        }
    }
}
