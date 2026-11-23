//! Requested bytes in live allocations owned by the Rust core and its bridge.
//! Native libraries, thread stacks and allocator overhead are outside this count.

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};

struct CoreAllocator;

#[global_allocator]
static ALLOCATOR: CoreAllocator = CoreAllocator;
static LIVE: AtomicUsize = AtomicUsize::new(0);

pub(crate) fn allocated_bytes() -> u64 {
    LIVE.load(Ordering::Relaxed) as u64
}

// SAFETY: every operation forwards the original pointer, size and alignment to
// System. Accounting uses only non-allocating atomics and never unwinds.
unsafe impl GlobalAlloc for CoreAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let ptr = unsafe { System.alloc(layout) };
        if !ptr.is_null() {
            LIVE.fetch_add(layout.size(), Ordering::Relaxed);
        }
        ptr
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let ptr = unsafe { System.alloc_zeroed(layout) };
        if !ptr.is_null() {
            LIVE.fetch_add(layout.size(), Ordering::Relaxed);
        }
        ptr
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
        unsafe { System.dealloc(ptr, layout) };
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        let resized = unsafe { System.realloc(ptr, layout, size) };
        if !resized.is_null() {
            if size >= layout.size() {
                LIVE.fetch_add(size - layout.size(), Ordering::Relaxed);
            } else {
                LIVE.fetch_sub(layout.size() - size, Ordering::Relaxed);
            }
        }
        resized
    }
}
