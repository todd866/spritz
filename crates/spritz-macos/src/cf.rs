use std::collections::VecDeque;
use std::ffi::{c_char, c_void, CStr};
use std::ptr::{self, NonNull};
use std::sync::{Mutex, OnceLock};

pub type Boolean = u8;
pub type CFIndex = isize;
pub type CFTypeID = usize;
pub type CFTypeRef = *const c_void;
pub type CFStringRef = *const c_void;
pub type CFStringEncoding = u32;
pub type CFAllocatorRef = *const c_void;
pub type CFRunLoopRef = *const c_void;
pub type CFRunLoopMode = CFStringRef;
pub type CFRunLoopSourceRef = *const c_void;
pub type CFRunLoopTimerRef = *const c_void;
pub type CFTimeInterval = f64;
pub type CFAbsoluteTime = f64;

pub const K_CF_STRING_ENCODING_UTF8: CFStringEncoding = 0x0800_0100;

#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct CGPoint {
    pub x: f64,
    pub y: f64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct CGSize {
    pub width: f64,
    pub height: f64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct CGRect {
    pub origin: CGPoint,
    pub size: CGSize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CFRange {
    pub location: CFIndex,
    pub length: CFIndex,
}

#[repr(C)]
pub struct CFRunLoopSourceContext {
    pub version: CFIndex,
    pub info: *mut c_void,
    pub retain: Option<extern "C" fn(*const c_void) -> *const c_void>,
    pub release: Option<extern "C" fn(*const c_void)>,
    pub copy_description: Option<extern "C" fn(*const c_void) -> CFStringRef>,
    pub equal: Option<extern "C" fn(*const c_void, *const c_void) -> Boolean>,
    pub hash: Option<extern "C" fn(*const c_void) -> usize>,
    pub schedule: Option<extern "C" fn(*mut c_void, CFRunLoopRef, CFRunLoopMode)>,
    pub cancel: Option<extern "C" fn(*mut c_void, CFRunLoopRef, CFRunLoopMode)>,
    pub perform: Option<extern "C" fn(*mut c_void)>,
}

#[repr(C)]
pub struct CFRunLoopTimerContext {
    pub version: CFIndex,
    pub info: *mut c_void,
    pub retain: Option<extern "C" fn(*const c_void) -> *const c_void>,
    pub release: Option<extern "C" fn(*const c_void)>,
    pub copy_description: Option<extern "C" fn(*const c_void) -> CFStringRef>,
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    pub static kCFAllocatorDefault: CFAllocatorRef;
    pub static kCFRunLoopCommonModes: CFRunLoopMode;
    pub static kCFBooleanTrue: CFTypeRef;

    pub fn CFRetain(cf: CFTypeRef) -> CFTypeRef;
    pub fn CFRelease(cf: CFTypeRef);
    pub fn CFEqual(cf1: CFTypeRef, cf2: CFTypeRef) -> Boolean;
    pub fn CFGetTypeID(cf: CFTypeRef) -> CFTypeID;

    pub fn CFStringCreateWithCString(
        alloc: CFAllocatorRef,
        c_str: *const c_char,
        encoding: CFStringEncoding,
    ) -> CFStringRef;
    pub fn CFStringGetCString(
        the_string: CFStringRef,
        buffer: *mut c_char,
        buffer_size: CFIndex,
        encoding: CFStringEncoding,
    ) -> Boolean;
    pub fn CFStringGetLength(the_string: CFStringRef) -> CFIndex;
    pub fn CFStringGetMaximumSizeForEncoding(
        length: CFIndex,
        encoding: CFStringEncoding,
    ) -> CFIndex;
    pub fn CFStringGetTypeID() -> CFTypeID;

    pub fn CFNumberGetTypeID() -> CFTypeID;
    pub fn CFNumberCreate(alloc: CFAllocatorRef, the_type: CFIndex, value_ptr: *const c_void) -> CFTypeRef;
    pub fn CFNumberGetValue(number: CFTypeRef, the_type: CFIndex, value_ptr: *mut c_void) -> Boolean;

    pub fn CFBooleanGetTypeID() -> CFTypeID;
    pub fn CFBooleanGetValue(boolean: CFTypeRef) -> Boolean;

    pub fn CFArrayGetTypeID() -> CFTypeID;
    pub fn CFArrayGetCount(the_array: CFTypeRef) -> CFIndex;
    pub fn CFArrayGetValueAtIndex(the_array: CFTypeRef, idx: CFIndex) -> CFTypeRef;

    pub fn CFDictionaryGetTypeID() -> CFTypeID;
    pub fn CFDictionaryGetValue(the_dict: CFTypeRef, key: *const c_void) -> CFTypeRef;

    pub fn CFAbsoluteTimeGetCurrent() -> CFAbsoluteTime;
    pub fn CFRunLoopGetMain() -> CFRunLoopRef;
    pub fn CFRunLoopGetCurrent() -> CFRunLoopRef;
    pub fn CFRunLoopAddSource(rl: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFRunLoopMode);
    pub fn CFRunLoopRemoveSource(rl: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFRunLoopMode);
    pub fn CFRunLoopSourceCreate(
        allocator: CFAllocatorRef,
        order: CFIndex,
        context: *mut CFRunLoopSourceContext,
    ) -> CFRunLoopSourceRef;
    pub fn CFRunLoopSourceSignal(source: CFRunLoopSourceRef);
    pub fn CFRunLoopSourceInvalidate(source: CFRunLoopSourceRef);
    pub fn CFRunLoopWakeUp(rl: CFRunLoopRef);

    pub fn CFRunLoopTimerCreate(
        allocator: CFAllocatorRef,
        fire_date: CFAbsoluteTime,
        interval: CFTimeInterval,
        flags: usize,
        order: CFIndex,
        callout: extern "C" fn(CFRunLoopTimerRef, *mut c_void),
        context: *mut CFRunLoopTimerContext,
    ) -> CFRunLoopTimerRef;
    pub fn CFRunLoopAddTimer(rl: CFRunLoopRef, timer: CFRunLoopTimerRef, mode: CFRunLoopMode);
    pub fn CFRunLoopTimerInvalidate(timer: CFRunLoopTimerRef);

    pub fn CFPreferencesCopyAppValue(key: CFStringRef, application_id: CFStringRef) -> CFTypeRef;
    pub fn CFPreferencesSetAppValue(key: CFStringRef, value: CFTypeRef, application_id: CFStringRef);
    pub fn CFPreferencesAppSynchronize(application_id: CFStringRef) -> Boolean;
}

pub const K_CF_NUMBER_SINT32_TYPE: CFIndex = 3;
pub const K_CF_NUMBER_SINT64_TYPE: CFIndex = 4;

/// Owned, reference-counted wrapper around any `CFTypeRef`.
#[derive(Debug)]
pub struct CFRef {
    ptr: NonNull<c_void>,
}

unsafe impl Send for CFRef {}
unsafe impl Sync for CFRef {}

impl CFRef {
    /// Takes ownership of a `+1` retained CoreFoundation reference (Create/Copy rule).
    pub unsafe fn from_owned(ptr: CFTypeRef) -> Option<Self> {
        NonNull::new(ptr as *mut c_void).map(|p| Self { ptr: p })
    }

    /// Retains a `+0` unowned CoreFoundation reference (Get rule).
    pub unsafe fn retain(ptr: CFTypeRef) -> Option<Self> {
        if ptr.is_null() {
            return None;
        }
        let retained = CFRetain(ptr);
        NonNull::new(retained as *mut c_void).map(|p| Self { ptr: p })
    }

    pub fn as_ptr(&self) -> CFTypeRef {
        self.ptr.as_ptr()
    }
}

impl Clone for CFRef {
    fn clone(&self) -> Self {
        unsafe {
            let p = CFRetain(self.ptr.as_ptr());
            Self {
                ptr: NonNull::new_unchecked(p as *mut c_void),
            }
        }
    }
}

impl Drop for CFRef {
    fn drop(&mut self) {
        unsafe { CFRelease(self.ptr.as_ptr()) }
    }
}

impl PartialEq for CFRef {
    fn eq(&self, other: &Self) -> bool {
        unsafe { CFEqual(self.as_ptr(), other.as_ptr()) != 0 }
    }
}

impl Eq for CFRef {}

pub fn cfstr(s: &str) -> CFRef {
    let c = std::ffi::CString::new(s).expect("CFString must not contain interior NUL");
    unsafe {
        let raw = CFStringCreateWithCString(kCFAllocatorDefault, c.as_ptr(), K_CF_STRING_ENCODING_UTF8);
        CFRef::from_owned(raw).expect("CFStringCreateWithCString returned null")
    }
}

pub fn cfstring_to_rust(ptr: CFTypeRef) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe {
        if CFGetTypeID(ptr) != CFStringGetTypeID() {
            return None;
        }
        let len = CFStringGetLength(ptr);
        let max = CFStringGetMaximumSizeForEncoding(len, K_CF_STRING_ENCODING_UTF8) + 1;
        let mut buf = vec![0u8; max.max(1) as usize];
        if CFStringGetCString(
            ptr,
            buf.as_mut_ptr() as *mut c_char,
            buf.len() as CFIndex,
            K_CF_STRING_ENCODING_UTF8,
        ) == 0
        {
            return None;
        }
        let cstr = CStr::from_ptr(buf.as_ptr() as *const c_char);
        Some(cstr.to_string_lossy().into_owned())
    }
}

pub fn cfnumber_to_i64(ptr: CFTypeRef) -> Option<i64> {
    if ptr.is_null() {
        return None;
    }
    unsafe {
        if CFGetTypeID(ptr) != CFNumberGetTypeID() {
            return None;
        }
        let mut val: i64 = 0;
        if CFNumberGetValue(ptr, K_CF_NUMBER_SINT64_TYPE, &mut val as *mut i64 as *mut c_void) != 0
        {
            Some(val)
        } else {
            None
        }
    }
}

pub fn cfboolean_to_bool(ptr: CFTypeRef) -> Option<bool> {
    if ptr.is_null() {
        return None;
    }
    unsafe {
        if CFGetTypeID(ptr) != CFBooleanGetTypeID() {
            return None;
        }
        Some(CFBooleanGetValue(ptr) != 0)
    }
}

pub fn monotonic_uptime_secs() -> f64 {
    mach_continuous_secs()
}

fn mach_continuous_secs() -> f64 {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    unsafe {
        libc::clock_gettime(libc::CLOCK_UPTIME_RAW, &mut ts);
    }
    ts.tv_sec as f64 + (ts.tv_nsec as f64) / 1_000_000_000.0
}

pub fn epoch_secs() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

// MARK: - Main-thread CFRunLoopSource dispatcher (zero ObjC blocks required)

type MainJob = Box<dyn FnOnce() + Send>;

struct Dispatcher {
    queue: Mutex<VecDeque<MainJob>>,
    source: usize, // CFRunLoopSourceRef as usize so Sync holds cleanly
    main_rl: usize,
}

static DISPATCHER: OnceLock<Dispatcher> = OnceLock::new();

extern "C" fn perform_main_jobs(_info: *mut c_void) {
    let Some(d) = DISPATCHER.get() else {
        return;
    };
    loop {
        let next = {
            let mut q = d.queue.lock().unwrap();
            q.pop_front()
        };
        let Some(job) = next else {
            break;
        };
        job();
    }
}

fn dispatcher() -> &'static Dispatcher {
    DISPATCHER.get_or_init(|| unsafe {
        let mut ctx = CFRunLoopSourceContext {
            version: 0,
            info: ptr::null_mut(),
            retain: None,
            release: None,
            copy_description: None,
            equal: None,
            hash: None,
            schedule: None,
            cancel: None,
            perform: Some(perform_main_jobs),
        };
        let src = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &mut ctx);
        let main_rl = CFRunLoopGetMain();
        CFRunLoopAddSource(main_rl, src, kCFRunLoopCommonModes);
        Dispatcher {
            queue: Mutex::new(VecDeque::new()),
            source: src as usize,
            main_rl: main_rl as usize,
        }
    })
}

pub fn ensure_main_dispatcher_installed() {
    let _ = dispatcher();
}

pub fn dispatch_main<F: FnOnce() + Send + 'static>(job: F) {
    let d = dispatcher();
    {
        let mut q = d.queue.lock().unwrap();
        q.push_back(Box::new(job));
    }
    unsafe {
        CFRunLoopSourceSignal(d.source as CFRunLoopSourceRef);
        CFRunLoopWakeUp(d.main_rl as CFRunLoopRef);
    }
}

/// One-shot cancellable timer running on the current (`main`) CFRunLoop.
pub struct MainTimer {
    timer: CFRef,
}

impl MainTimer {
    pub fn after_secs<F: FnOnce() + 'static>(delay_secs: f64, callback: F) -> Option<Self> {
        let cb_box: Box<Option<Box<dyn FnOnce()>>> = Box::new(Some(Box::new(callback)));
        let raw_info = Box::into_raw(cb_box) as *mut c_void;

        extern "C" fn release_box(ptr: *const c_void) {
            if !ptr.is_null() {
                unsafe {
                    drop(Box::from_raw(ptr as *mut Option<Box<dyn FnOnce()>>));
                }
            }
        }

        extern "C" fn fire_timer(_timer: CFRunLoopTimerRef, info: *mut c_void) {
            if info.is_null() {
                return;
            }
            unsafe {
                let slot = &mut *(info as *mut Option<Box<dyn FnOnce()>>);
                if let Some(cb) = slot.take() {
                    cb();
                }
            }
        }

        unsafe {
            let mut ctx = CFRunLoopTimerContext {
                version: 0,
                info: raw_info,
                retain: None,
                release: Some(release_box),
                copy_description: None,
            };
            let fire_at = CFAbsoluteTimeGetCurrent() + delay_secs.max(0.0);
            let raw_timer = CFRunLoopTimerCreate(
                kCFAllocatorDefault,
                fire_at,
                0.0,
                0,
                0,
                fire_timer,
                &mut ctx,
            );
            let Some(timer) = CFRef::from_owned(raw_timer) else {
                release_box(raw_info);
                return None;
            };
            CFRunLoopAddTimer(CFRunLoopGetMain(), timer.as_ptr(), kCFRunLoopCommonModes);
            Some(Self { timer })
        }
    }
}

impl Drop for MainTimer {
    fn drop(&mut self) {
        unsafe {
            CFRunLoopTimerInvalidate(self.timer.as_ptr());
        }
    }
}
