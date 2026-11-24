use crate::cf::{
    cfnumber_to_i64, cfstr, cfstring_to_rust, dispatch_main, kCFRunLoopCommonModes,
    monotonic_uptime_secs, Boolean, CFGetTypeID, CFIndex, CFRange, CFRef, CFRunLoopAddSource,
    CFRunLoopGetMain, CFRunLoopRemoveSource, CFRunLoopSourceRef, CFStringRef, CFTypeID, CFTypeRef,
    CGPoint, CGRect, CGSize,
};
use std::ffi::c_void;
use std::ptr;

pub type AXError = i32;
pub type AXUIElementRef = CFTypeRef;
pub type AXValueRef = CFTypeRef;
pub type AXObserverRef = CFTypeRef;
pub type AXValueType = u32;

pub const K_AX_ERROR_SUCCESS: AXError = 0;
pub const K_AX_VALUE_CGPOINT_TYPE: AXValueType = 1;
pub const K_AX_VALUE_CGSIZE_TYPE: AXValueType = 2;
pub const K_AX_VALUE_CGRECT_TYPE: AXValueType = 3;
pub const K_AX_VALUE_CFRANGE_TYPE: AXValueType = 4;

type AXObserverCallback = extern "C" fn(
    observer: AXObserverRef,
    element: AXUIElementRef,
    notification: CFStringRef,
    refcon: *mut c_void,
);

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    pub fn AXIsProcessTrusted() -> Boolean;
    pub fn AXUIElementGetTypeID() -> CFTypeID;
    pub fn AXValueGetTypeID() -> CFTypeID;
    pub fn AXUIElementCreateSystemWide() -> AXUIElementRef;
    pub fn AXUIElementCreateApplication(pid: libc::pid_t) -> AXUIElementRef;
    pub fn AXUIElementSetMessagingTimeout(element: AXUIElementRef, timeout_in_seconds: f32) -> AXError;
    pub fn AXUIElementCopyAttributeValue(
        element: AXUIElementRef,
        attribute: CFStringRef,
        value: *mut CFTypeRef,
    ) -> AXError;
    pub fn AXUIElementIsAttributeSettable(
        element: AXUIElementRef,
        attribute: CFStringRef,
        settable: *mut Boolean,
    ) -> AXError;
    pub fn AXUIElementCopyParameterizedAttributeValue(
        element: AXUIElementRef,
        parameterized_attribute: CFStringRef,
        parameter: CFTypeRef,
        result: *mut CFTypeRef,
    ) -> AXError;
    pub fn AXValueCreate(the_type: AXValueType, value_ptr: *const c_void) -> AXValueRef;
    pub fn AXValueGetValue(
        value: AXValueRef,
        the_type: AXValueType,
        value_ptr: *mut c_void,
    ) -> Boolean;
    pub fn AXObserverCreate(
        application: libc::pid_t,
        callback: AXObserverCallback,
        out_observer: *mut AXObserverRef,
    ) -> AXError;
    pub fn AXObserverAddNotification(
        observer: AXObserverRef,
        element: AXUIElementRef,
        notification: CFStringRef,
        refcon: *mut c_void,
    ) -> AXError;
    pub fn AXObserverGetRunLoopSource(observer: AXObserverRef) -> CFRunLoopSourceRef;
}

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    pub fn CGMainDisplayID() -> u32;
    pub fn CGDisplayBounds(display: u32) -> CGRect;
    pub fn CGGetActiveDisplayList(
        max_displays: u32,
        active_displays: *mut u32,
        display_count: *mut u32,
    ) -> i32;
}

pub fn set_global_ax_timeout(secs: f32) {
    unsafe {
        if let Some(sys) = CFRef::from_owned(AXUIElementCreateSystemWide()) {
            AXUIElementSetMessagingTimeout(sys.as_ptr(), secs);
        }
    }
}

pub fn is_accessibility_trusted() -> bool {
    unsafe { AXIsProcessTrusted() != 0 }
}

pub fn copy_ax_attr(el: &CFRef, attr: &str) -> Option<CFRef> {
    let key = cfstr(attr);
    let mut out: CFTypeRef = ptr::null();
    unsafe {
        if AXUIElementCopyAttributeValue(el.as_ptr(), key.as_ptr(), &mut out) == K_AX_ERROR_SUCCESS {
            CFRef::from_owned(out)
        } else {
            None
        }
    }
}

pub fn is_ax_attr_settable(el: &CFRef, attr: &str) -> bool {
    let key = cfstr(attr);
    let mut settable: Boolean = 0;
    unsafe {
        AXUIElementIsAttributeSettable(el.as_ptr(), key.as_ptr(), &mut settable) == K_AX_ERROR_SUCCESS
            && settable != 0
    }
}

pub fn copy_ax_string(el: &CFRef, attr: &str) -> Option<String> {
    let v = copy_ax_attr(el, attr)?;
    cfstring_to_rust(v.as_ptr())
}

pub fn is_ax_element(val: &CFRef) -> bool {
    unsafe { CFGetTypeID(val.as_ptr()) == AXUIElementGetTypeID() }
}

pub fn read_ax_range(el: &CFRef, attr: &str) -> Option<CFRange> {
    let v = copy_ax_attr(el, attr)?;
    unsafe {
        if CFGetTypeID(v.as_ptr()) != AXValueGetTypeID() {
            return None;
        }
        let mut r = CFRange::default();
        if AXValueGetValue(v.as_ptr(), K_AX_VALUE_CFRANGE_TYPE, &mut r as *mut CFRange as *mut c_void) != 0
            && r.location >= 0
            && r.length >= 0
        {
            Some(r)
        } else {
            None
        }
    }
}

pub fn read_ax_rect(el: &CFRef) -> Option<CGRect> {
    let pos = copy_ax_attr(el, "AXPosition")?;
    let size = copy_ax_attr(el, "AXSize")?;
    unsafe {
        if CFGetTypeID(pos.as_ptr()) != AXValueGetTypeID()
            || CFGetTypeID(size.as_ptr()) != AXValueGetTypeID()
        {
            return None;
        }
        let mut origin = CGPoint::default();
        let mut sz = CGSize::default();
        if AXValueGetValue(pos.as_ptr(), K_AX_VALUE_CGPOINT_TYPE, &mut origin as *mut CGPoint as *mut c_void) == 0
            || AXValueGetValue(size.as_ptr(), K_AX_VALUE_CGSIZE_TYPE, &mut sz as *mut CGSize as *mut c_void) == 0
        {
            return None;
        }
        if sz.width <= 0.0 || sz.height <= 0.0 {
            return None;
        }
        Some(convert_ax_rect_to_appkit(CGRect { origin, size: sz }))
    }
}

pub fn bounds_for_range_ax(el: &CFRef, range: CFRange) -> Option<CGRect> {
    unsafe {
        let param = CFRef::from_owned(AXValueCreate(
            K_AX_VALUE_CFRANGE_TYPE,
            &range as *const CFRange as *const c_void,
        ))?;
        let key = cfstr("AXBoundsForRange");
        let mut result: CFTypeRef = ptr::null();
        if AXUIElementCopyParameterizedAttributeValue(el.as_ptr(), key.as_ptr(), param.as_ptr(), &mut result)
            != K_AX_ERROR_SUCCESS
        {
            return None;
        }
        let res_ref = CFRef::from_owned(result)?;
        if CFGetTypeID(res_ref.as_ptr()) != AXValueGetTypeID() {
            return None;
        }
        let mut rect = CGRect::default();
        if AXValueGetValue(res_ref.as_ptr(), K_AX_VALUE_CGRECT_TYPE, &mut rect as *mut CGRect as *mut c_void) == 0 {
            return None;
        }
        if rect.size.width >= 0.0 && rect.size.height > 0.0 {
            Some(rect)
        } else {
            None
        }
    }
}

pub fn string_for_range_ax(el: &CFRef, range: CFRange) -> Option<String> {
    unsafe {
        let param = CFRef::from_owned(AXValueCreate(
            K_AX_VALUE_CFRANGE_TYPE,
            &range as *const CFRange as *const c_void,
        ))?;
        let key = cfstr("AXStringForRange");
        let mut result: CFTypeRef = ptr::null();
        if AXUIElementCopyParameterizedAttributeValue(el.as_ptr(), key.as_ptr(), param.as_ptr(), &mut result)
            != K_AX_ERROR_SUCCESS
        {
            return None;
        }
        let res_ref = CFRef::from_owned(result)?;
        cfstring_to_rust(res_ref.as_ptr())
    }
}

pub fn active_screen_frames_appkit() -> Vec<CGRect> {
    unsafe {
        let main_h = CGDisplayBounds(CGMainDisplayID()).size.height;
        let mut ids = [0u32; 16];
        let mut count: u32 = 0;
        if CGGetActiveDisplayList(16, ids.as_mut_ptr(), &mut count) != 0 || count == 0 {
            let b = CGDisplayBounds(CGMainDisplayID());
            return vec![convert_cg_rect_to_appkit(b, main_h)];
        }
        ids[..count as usize]
            .iter()
            .map(|&id| convert_cg_rect_to_appkit(CGDisplayBounds(id), main_h))
            .collect()
    }
}

pub fn convert_cg_rect_to_appkit(r: CGRect, primary_height: f64) -> CGRect {
    CGRect {
        origin: CGPoint {
            x: r.origin.x,
            y: primary_height - r.origin.y - r.size.height,
        },
        size: r.size,
    }
}

pub fn convert_ax_rect_to_appkit(r: CGRect) -> CGRect {
    let primary_h = unsafe { CGDisplayBounds(CGMainDisplayID()).size.height };
    convert_cg_rect_to_appkit(r, primary_h)
}

pub fn is_classic_text_role(role: Option<&str>) -> bool {
    matches!(
        role,
        Some("AXTextField" | "AXTextArea" | "AXComboBox" | "AXSearchField" | "AXSecureTextField")
    )
}

pub fn evaluate_editability(
    role: Option<&str>,
    subrole: Option<&str>,
    value_settable: bool,
    has_selected_range: bool,
    has_editable_ancestor: bool,
) -> (bool, bool) {
    if role == Some("AXSecureTextField") || subrole == Some("AXSecureTextField") {
        return (false, true);
    }
    if matches!(
        role,
        Some("AXTextField" | "AXTextArea" | "AXComboBox" | "AXSearchField")
    ) {
        return (true, false);
    }
    if has_editable_ancestor {
        return (true, false);
    }
    if value_settable && has_selected_range {
        return (true, false);
    }
    if value_settable && !matches!(role, Some("AXWindow" | "AXApplication" | "AXScrollArea")) {
        return (true, false);
    }
    (false, false)
}

#[derive(Debug, Clone)]
pub struct FocusSnapshot {
    pub element: Option<CFRef>,
    pub pid: i32,
    pub role: Option<String>,
    pub have_field_info: bool,
    pub is_editable: bool,
    pub is_secure: bool,
    pub window_frame: Option<CGRect>,
}

pub fn inspect_focused_element_for_pid(pid: i32, timeout_secs: f32) -> FocusSnapshot {
    unsafe {
        let Some(app) = CFRef::from_owned(AXUIElementCreateApplication(pid)) else {
            return FocusSnapshot {
                element: None,
                pid,
                role: None,
                have_field_info: false,
                is_editable: false,
                is_secure: false,
                window_frame: None,
            };
        };
        AXUIElementSetMessagingTimeout(app.as_ptr(), timeout_secs);
        let window_frame = copy_ax_attr(&app, "AXFocusedWindow")
            .filter(is_ax_element)
            .and_then(|w| read_ax_rect(&w));

        let Some(focused) = copy_ax_attr(&app, "AXFocusedUIElement").filter(is_ax_element) else {
            return FocusSnapshot {
                element: None,
                pid,
                role: None,
                have_field_info: false,
                is_editable: false,
                is_secure: false,
                window_frame,
            };
        };
        AXUIElementSetMessagingTimeout(focused.as_ptr(), timeout_secs);
        let role = copy_ax_string(&focused, "AXRole");
        let subrole = copy_ax_string(&focused, "AXSubrole");
        let value_settable = is_ax_attr_settable(&focused, "AXValue");
        let has_selected_range = read_ax_range(&focused, "AXSelectedTextRange").is_some();
        let has_editable_ancestor = copy_ax_attr(&focused, "AXEditableAncestor")
            .filter(is_ax_element)
            .is_some();
        let (is_editable, is_secure) = evaluate_editability(
            role.as_deref(),
            subrole.as_deref(),
            value_settable,
            has_selected_range,
            has_editable_ancestor,
        );

        FocusSnapshot {
            element: Some(focused),
            pid,
            role,
            have_field_info: true,
            is_editable,
            is_secure,
            window_frame,
        }
    }
}

/// Fast (~5ms timeout) tap-time AX verification for TouchBar requests.
pub fn verify_focused_element_fast(pid: i32, expected: &CFRef) -> bool {
    unsafe {
        let Some(app) = CFRef::from_owned(AXUIElementCreateApplication(pid)) else {
            return false;
        };
        AXUIElementSetMessagingTimeout(app.as_ptr(), 0.005);
        let Some(actual) = copy_ax_attr(&app, "AXFocusedUIElement").filter(is_ax_element) else {
            return false;
        };
        actual == *expected
    }
}

pub fn focused_field_char_count(element: Option<&CFRef>) -> Option<usize> {
    let el = element?;
    let val = copy_ax_attr(el, "AXNumberOfCharacters")?;
    let n = cfnumber_to_i64(val.as_ptr())?;
    (n >= 0).then_some(n as usize)
}

/// Reads `(value, sel_loc_utf16, sel_len_utf16)` with bounded timeout on background thread.
pub fn read_field_value_and_selection(
    element: &CFRef,
    timeout_secs: f32,
) -> Option<(String, usize, usize)> {
    unsafe {
        AXUIElementSetMessagingTimeout(element.as_ptr(), timeout_secs);
    }
    let val = copy_ax_string(element, "AXValue")?;
    let range = read_ax_range(element, "AXSelectedTextRange")?;
    Some((val, range.location as usize, range.length as usize))
}

/// Reads up to 200 UTF-16 chars preceding the caret when the focused field is non-secure.
pub fn read_preceding_context(element: &CFRef) -> Option<String> {
    let role = copy_ax_string(element, "AXRole");
    let subrole = copy_ax_string(element, "AXSubrole");
    if role.as_deref() == Some("AXSecureTextField")
        || subrole.as_deref() == Some("AXSecureTextField")
    {
        return None;
    }
    let range = read_ax_range(element, "AXSelectedTextRange")?;
    if range.location <= 0 {
        return None;
    }
    let len = range.location.min(200);
    let start = range.location - len;
    let slice = string_for_range_ax(
        element,
        CFRange {
            location: start,
            length: len,
        },
    )?;
    if !slice.is_empty() {
        return Some(slice);
    }
    None
}

// MARK: - Caret resolution

pub fn resolve_caret_ax<F, G>(
    sel: CFRange,
    mut bounds_for: F,
    mut char_at: G,
) -> Option<CGRect>
where
    F: FnMut(CFRange) -> Option<CGRect>,
    G: FnMut(CFIndex) -> Option<String>,
{
    let probe_len = sel.length.max(1);
    if let Some(next) = bounds_for(CFRange {
        location: sel.location,
        length: probe_len,
    }) {
        return Some(next);
    }
    if sel.location > 0 {
        if let Some(prev_ch) = char_at(sel.location - 1) {
            if !prev_ch.contains('\n') && !prev_ch.contains('\r') {
                if let Some(glyph) = bounds_for(CFRange {
                    location: sel.location - 1,
                    length: 1,
                }) {
                    return Some(CGRect {
                        origin: CGPoint {
                            x: glyph.origin.x + glyph.size.width,
                            y: glyph.origin.y,
                        },
                        size: CGSize {
                            width: 0.0,
                            height: glyph.size.height,
                        },
                    });
                }
            }
        }
    }
    bounds_for(CFRange {
        location: sel.location,
        length: 0,
    })
}

fn rects_intersect(a: CGRect, b: CGRect) -> bool {
    a.origin.x < b.origin.x + b.size.width
        && a.origin.x + a.size.width > b.origin.x
        && a.origin.y < b.origin.y + b.size.height
        && a.origin.y + a.size.height > b.origin.y
}

fn is_on_screen(rect: CGRect, screens: &[CGRect]) -> bool {
    screens.iter().any(|&s| rects_intersect(rect, s))
}

pub fn window_fallback_rect(win: CGRect, screens: &[CGRect]) -> Option<CGRect> {
    if win.size.width < 240.0 || win.size.height < 120.0 || !is_on_screen(win, screens) {
        return None;
    }
    let y = win.origin.y + (win.size.height * 0.18).clamp(36.0, 120.0);
    let max_y = win.origin.y + win.size.height - 24.0;
    let rect = CGRect {
        origin: CGPoint {
            x: win.origin.x + win.size.width * 0.5 - 0.5,
            y: y.min(max_y),
        },
        size: CGSize {
            width: 1.0,
            height: 22.0,
        },
    };
    is_on_screen(rect, screens).then_some(rect)
}

#[derive(Debug, Clone, Copy)]
pub struct CaretResolution {
    pub rect: Option<CGRect>,
    pub by_fallback: bool,
}

pub fn resolve_caret_for_cache(cache: &FocusedElementCache) -> CaretResolution {
    let screens = active_screen_frames_appkit();
    let focused = cache.element.clone().or_else(|| unsafe {
        let sys = CFRef::from_owned(AXUIElementCreateSystemWide())?;
        copy_ax_attr(&sys, "AXFocusedUIElement").filter(is_ax_element)
    });

    let element_frame = focused.as_ref().and_then(read_ax_rect);
    if let Some(el) = focused.as_ref() {
        if let Some(range) = read_ax_range(el, "AXSelectedTextRange") {
            let ax_rect = resolve_caret_ax(
                range,
                |r| bounds_for_range_ax(el, r),
                |loc| string_for_range_ax(el, CFRange { location: loc, length: 1 }),
            );
            if let Some(raw) = ax_rect {
                let appkit = convert_ax_rect_to_appkit(raw);
                let plausible = is_on_screen(appkit, &screens)
                    && element_frame.map_or(true, |ef| {
                        let mid_x = appkit.origin.x + appkit.size.width * 0.5;
                        let mid_y = appkit.origin.y + appkit.size.height * 0.5;
                        mid_x >= ef.origin.x - 8.0
                            && mid_x <= ef.origin.x + ef.size.width + 8.0
                            && mid_y >= ef.origin.y - 8.0
                            && mid_y <= ef.origin.y + ef.size.height + 8.0
                    });
                if plausible {
                    return CaretResolution {
                        rect: Some(appkit),
                        by_fallback: false,
                    };
                }
            }
        }
    }

    if let Some(frame) = element_frame {
        let text_role = is_classic_text_role(cache.role.as_deref()) || cache.is_editable;
        if text_role
            && is_on_screen(frame, &screens)
            && frame.size.width < 4000.0
            && frame.size.height < 4000.0
        {
            let tall = frame.size.height > 160.0;
            let caret_h = frame.size.height.clamp(16.0, 22.0);
            let x = if tall {
                frame.origin.x + frame.size.width * 0.5
            } else {
                frame.origin.x + 4.0
            };
            let y = if tall {
                frame.origin.y + (frame.size.height * 0.18).clamp(36.0, 120.0)
            } else {
                frame.origin.y + frame.size.height - caret_h - 2.0
            };
            return CaretResolution {
                rect: Some(CGRect {
                    origin: CGPoint { x, y },
                    size: CGSize {
                        width: 1.0,
                        height: caret_h,
                    },
                }),
                by_fallback: true,
            };
        }
    }

    if let Some(win) = cache.active_window_frame {
        if let Some(rect) = window_fallback_rect(win, &screens) {
            return CaretResolution {
                rect: Some(rect),
                by_fallback: true,
            };
        }
    }

    CaretResolution {
        rect: None,
        by_fallback: true,
    }
}

// MARK: - FocusedElementCache + AXObserver

struct ActiveObserver {
    _observer: CFRef,
    source: usize, // unowned AXObserverGetRunLoopSource ptr
    ctx_ptr: *mut ObserverCookie,
}

impl Drop for ActiveObserver {
    fn drop(&mut self) {
        unsafe {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                self.source as CFRunLoopSourceRef,
                kCFRunLoopCommonModes,
            );
            drop(Box::from_raw(self.ctx_ptr));
        }
    }
}

struct ObserverCookie {
    pid: i32,
    callback: fn(i32, Option<CFRef>, bool),
}

extern "C" fn ax_observer_trampoline(
    _observer: AXObserverRef,
    element: AXUIElementRef,
    notification: CFStringRef,
    refcon: *mut c_void,
) {
    if refcon.is_null() {
        return;
    }
    unsafe {
        let cookie = &*(refcon as *const ObserverCookie);
        let note = cfstring_to_rust(notification).unwrap_or_default();
        let is_window = note == "AXFocusedWindowChanged";
        let retained = CFRef::retain(element);
        (cookie.callback)(cookie.pid, retained, is_window);
    }
}

pub struct FocusedElementCache {
    pub element: Option<CFRef>,
    pub focused_pid: Option<i32>,
    pub front_bundle: String,
    pub role: Option<String>,
    pub have_field_info: bool,
    pub is_editable: bool,
    pub is_secure: bool,
    pub active_window_frame: Option<CGRect>,
    pub bridge_focus_generation: u64,
    last_stale_refresh_at: f64,
    refresh_seq: u64,
    observer: Option<ActiveObserver>,
}

impl Default for FocusedElementCache {
    fn default() -> Self {
        Self {
            element: None,
            focused_pid: None,
            front_bundle: String::new(),
            role: None,
            have_field_info: false,
            is_editable: false,
            is_secure: false,
            active_window_frame: None,
            bridge_focus_generation: 0,
            last_stale_refresh_at: 0.0,
            refresh_seq: 0,
            observer: None,
        }
    }
}

impl FocusedElementCache {
    pub fn observe_app(
        &mut self,
        pid: i32,
        bundle_id: String,
        on_event: fn(i32, Option<CFRef>, bool),
    ) {
        self.observer = None;
        self.element = None;
        self.focused_pid = Some(pid);
        self.front_bundle = bundle_id;
        self.role = None;
        self.have_field_info = false;
        self.is_editable = false;
        self.is_secure = false;
        self.active_window_frame = None;
        self.bridge_focus_generation = self.bridge_focus_generation.wrapping_add(1);
        self.last_stale_refresh_at = 0.0;

        if !is_accessibility_trusted() || pid <= 0 {
            return;
        }

        unsafe {
            let mut obs_raw: AXObserverRef = ptr::null();
            if AXObserverCreate(pid, ax_observer_trampoline, &mut obs_raw) != K_AX_ERROR_SUCCESS {
                return;
            }
            let Some(observer) = CFRef::from_owned(obs_raw) else {
                return;
            };
            let Some(app_el) = CFRef::from_owned(AXUIElementCreateApplication(pid)) else {
                return;
            };
            let cookie = Box::into_raw(Box::new(ObserverCookie {
                pid,
                callback: on_event,
            }));
            for note in ["AXFocusedUIElementChanged", "AXFocusedWindowChanged"] {
                let n = cfstr(note);
                AXObserverAddNotification(
                    observer.as_ptr(),
                    app_el.as_ptr(),
                    n.as_ptr(),
                    cookie as *mut c_void,
                );
            }
            let src = AXObserverGetRunLoopSource(observer.as_ptr());
            if !src.is_null() {
                CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
                self.observer = Some(ActiveObserver {
                    _observer: observer,
                    source: src as usize,
                    ctx_ptr: cookie,
                });
            } else {
                drop(Box::from_raw(cookie));
            }
        }
    }

    pub fn apply_snapshot(&mut self, snap: FocusSnapshot, bump_generation: bool) -> bool {
        if self.focused_pid != Some(snap.pid) {
            return false;
        }
        let changed = self.element != snap.element;
        self.element = snap.element;
        self.role = snap.role;
        self.have_field_info = snap.have_field_info;
        self.is_editable = snap.is_editable;
        self.is_secure = snap.is_secure;
        if snap.window_frame.is_some() {
            self.active_window_frame = snap.window_frame;
        }
        if bump_generation && changed {
            self.bridge_focus_generation = self.bridge_focus_generation.wrapping_add(1);
        }
        changed
    }

    pub fn apply_live_refresh(&mut self, snap: FocusSnapshot) -> bool {
        self.apply_snapshot(snap, true)
    }

    pub fn should_refresh_on_typing(&mut self) -> Option<i32> {
        let pid = self.focused_pid?;
        if is_classic_text_role(self.role.as_deref()) && self.is_editable {
            return None;
        }
        let now = monotonic_uptime_secs();
        if now - self.last_stale_refresh_at < 2.0 {
            return None;
        }
        self.last_stale_refresh_at = now;
        Some(pid)
    }

    pub fn next_refresh_seq(&mut self) -> u64 {
        self.refresh_seq = self.refresh_seq.wrapping_add(1);
        self.refresh_seq
    }
}

pub fn spawn_ax_snapshot<F>(pid: i32, seq: u64, timeout_secs: f32, on_done: F)
where
    F: FnOnce(u64, FocusSnapshot) + Send + 'static,
{
    std::thread::spawn(move || {
        let snap = inspect_focused_element_for_pid(pid, timeout_secs);
        dispatch_main(move || {
            on_done(seq, snap);
        });
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn editability_accepts_contenteditable_and_rejects_secure() {
        assert_eq!(evaluate_editability(Some("AXSecureTextField"), None, true, true, true), (false, true));
        assert_eq!(evaluate_editability(Some("AXTextField"), None, false, false, false), (true, false));
        // Chrome contenteditable child reporting AXStaticText with settable AXValue or AXEditableAncestor
        assert_eq!(evaluate_editability(Some("AXStaticText"), None, true, true, false), (true, false));
        assert_eq!(evaluate_editability(Some("AXHeading"), None, false, false, true), (true, false));
        assert_eq!(evaluate_editability(Some("AXButton"), None, false, false, false), (false, false));
    }

    #[test]
    fn window_fallback_and_y_flip_work() {
        let screen = CGRect {
            origin: CGPoint { x: 0.0, y: 0.0 },
            size: CGSize { width: 1512.0, height: 982.0 },
        };
        let ax_rect = CGRect {
            origin: CGPoint { x: 100.0, y: 100.0 },
            size: CGSize { width: 2.0, height: 20.0 },
        };
        let flipped = convert_cg_rect_to_appkit(ax_rect, 982.0);
        assert_eq!(flipped.origin.y, 862.0);

        let win = CGRect {
            origin: CGPoint { x: 100.0, y: 100.0 },
            size: CGSize { width: 800.0, height: 600.0 },
        };
        let fb = window_fallback_rect(win, &[screen]).expect("valid window fallback");
        assert!((fb.origin.x - 499.5).abs() < 0.01);
        assert!((fb.origin.y - 208.0).abs() < 0.01);
    }

    #[test]
    fn caret_resolution_prefers_next_then_prev_then_zero() {
        let end_glyph = CGRect {
            origin: CGPoint { x: 40.0, y: 100.0 },
            size: CGSize { width: 8.0, height: 18.0 },
        };
        let rect = resolve_caret_ax(
            CFRange { location: 5, length: 0 },
            |r| if r.location == 4 && r.length == 1 { Some(end_glyph) } else { None },
            |_| Some("a".to_string()),
        )
        .unwrap();
        assert_eq!(rect.origin.x, 48.0);
    }
}
