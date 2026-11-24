use crate::ax::focused_field_char_count;
use crate::cf::{CFRef, CFTypeRef};
use spritz_core::insertion::unicode_chunks;
use std::ffi::c_void;
use std::ptr;

pub const SYNTH_MARKER: i64 = 0x5350_525A; // ASCII "SPRZ"
const K_CG_EVENT_FLAG_MASK_SHIFT: u64 = 0x0002_0000;
const K_CG_EVENT_SOURCE_USER_DATA: u32 = 42;
const K_CG_HID_EVENT_TAP: u32 = 0;
const K_VK_DELETE: u16 = 0x33;
const K_VK_LEFT_ARROW: u16 = 0x7B;

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGEventCreateKeyboardEvent(
        source: *const c_void,
        virtual_key: u16,
        key_down: bool,
    ) -> CFTypeRef;
    fn CGEventSetFlags(event: CFTypeRef, flags: u64);
    fn CGEventSetIntegerValueField(event: CFTypeRef, field: u32, value: i64);
    fn CGEventKeyboardSetUnicodeString(
        event: CFTypeRef,
        string_length: usize,
        unicode_string: *const u16,
    );
    fn CGEventPost(tap: u32, event: CFTypeRef);
}

fn post_key(virtual_key: u16, flags: u64) -> bool {
    unsafe {
        let Some(down) = CFRef::from_owned(CGEventCreateKeyboardEvent(ptr::null(), virtual_key, true)) else {
            return false;
        };
        let Some(up) = CFRef::from_owned(CGEventCreateKeyboardEvent(ptr::null(), virtual_key, false)) else {
            return false;
        };
        CGEventSetFlags(down.as_ptr(), flags);
        CGEventSetFlags(up.as_ptr(), flags);
        CGEventSetIntegerValueField(down.as_ptr(), K_CG_EVENT_SOURCE_USER_DATA, SYNTH_MARKER);
        CGEventSetIntegerValueField(up.as_ptr(), K_CG_EVENT_SOURCE_USER_DATA, SYNTH_MARKER);
        CGEventPost(K_CG_HID_EVENT_TAP, down.as_ptr());
        CGEventPost(K_CG_HID_EVENT_TAP, up.as_ptr());
        true
    }
}

pub fn replace_text(
    delete_chars: usize,
    text: &str,
    focused_element: Option<&CFRef>,
) -> bool {
    let mut ok = true;
    if delete_chars > 0 {
        let field_len = focused_field_char_count(focused_element);
        let select_over = field_len.map_or(false, |len| len > 0 && len <= delete_chars);
        for _ in 0..delete_chars {
            if select_over {
                ok = post_key(K_VK_LEFT_ARROW, K_CG_EVENT_FLAG_MASK_SHIFT) && ok;
            } else {
                ok = post_key(K_VK_DELETE, 0) && ok;
            }
        }
    }

    for chunk in unicode_chunks(text, 20) {
        let utf16: Vec<u16> = chunk.encode_utf16().collect();
        if utf16.is_empty() {
            continue;
        }
        unsafe {
            let Some(down) = CFRef::from_owned(CGEventCreateKeyboardEvent(ptr::null(), 0, true)) else {
                ok = false;
                continue;
            };
            let Some(up) = CFRef::from_owned(CGEventCreateKeyboardEvent(ptr::null(), 0, false)) else {
                ok = false;
                continue;
            };
            CGEventSetFlags(down.as_ptr(), 0);
            CGEventSetFlags(up.as_ptr(), 0);
            CGEventKeyboardSetUnicodeString(down.as_ptr(), utf16.len(), utf16.as_ptr());
            CGEventKeyboardSetUnicodeString(up.as_ptr(), utf16.len(), utf16.as_ptr());
            CGEventSetIntegerValueField(down.as_ptr(), K_CG_EVENT_SOURCE_USER_DATA, SYNTH_MARKER);
            CGEventSetIntegerValueField(up.as_ptr(), K_CG_EVENT_SOURCE_USER_DATA, SYNTH_MARKER);
            CGEventPost(K_CG_HID_EVENT_TAP, down.as_ptr());
            CGEventPost(K_CG_HID_EVENT_TAP, up.as_ptr());
        }
    }
    ok
}
