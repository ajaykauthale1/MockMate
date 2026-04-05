use std::collections::VecDeque;

/// Thread-safe ring buffer for f32 PCM samples.
/// When full, the oldest samples are silently dropped.
pub struct RingBuffer {
    inner: VecDeque<f32>,
    capacity: usize,
}

impl RingBuffer {
    pub fn new(capacity: usize) -> Self {
        Self {
            inner: VecDeque::with_capacity(capacity),
            capacity,
        }
    }

    /// Push samples into the buffer, evicting oldest if over capacity.
    pub fn push_slice(&mut self, samples: &[f32]) {
        for &s in samples {
            if self.inner.len() == self.capacity {
                self.inner.pop_front();
            }
            self.inner.push_back(s);
        }
    }

    /// Drain all samples and return them.
    pub fn drain_all(&mut self) -> Vec<f32> {
        self.inner.drain(..).collect()
    }

    /// Drain the oldest `n` samples (or all if fewer available).
    pub fn drain_n(&mut self, n: usize) -> Vec<f32> {
        let take = n.min(self.inner.len());
        self.inner.drain(..take).collect()
    }

    /// View the last `n` samples without consuming them.
    pub fn peek_last(&self, n: usize) -> Vec<f32> {
        let start = self.inner.len().saturating_sub(n);
        self.inner.range(start..).copied().collect()
    }

    pub fn len(&self) -> usize {
        self.inner.len()
    }

    pub fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }

    pub fn capacity(&self) -> usize {
        self.capacity
    }

    pub fn is_full(&self) -> bool {
        self.inner.len() == self.capacity
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_is_empty() {
        let rb = RingBuffer::new(10);
        assert!(rb.is_empty());
        assert_eq!(rb.len(), 0);
        assert_eq!(rb.capacity(), 10);
    }

    #[test]
    fn push_and_drain_all() {
        let mut rb = RingBuffer::new(8);
        rb.push_slice(&[1.0, 2.0, 3.0]);
        let out = rb.drain_all();
        assert_eq!(out, vec![1.0, 2.0, 3.0]);
        assert!(rb.is_empty());
    }

    #[test]
    fn overflow_evicts_oldest() {
        let mut rb = RingBuffer::new(4);
        rb.push_slice(&[1.0, 2.0, 3.0, 4.0]); // full
        rb.push_slice(&[5.0]);                  // evicts 1.0
        let out = rb.drain_all();
        assert_eq!(out, vec![2.0, 3.0, 4.0, 5.0]);
    }

    #[test]
    fn overflow_large_batch() {
        let mut rb = RingBuffer::new(3);
        rb.push_slice(&[1.0, 2.0, 3.0, 4.0, 5.0]);
        let out = rb.drain_all();
        assert_eq!(out, vec![3.0, 4.0, 5.0]);
    }

    #[test]
    fn drain_n() {
        let mut rb = RingBuffer::new(8);
        rb.push_slice(&[1.0, 2.0, 3.0, 4.0]);
        let out = rb.drain_n(2);
        assert_eq!(out, vec![1.0, 2.0]);
        assert_eq!(rb.len(), 2);
    }

    #[test]
    fn drain_n_more_than_available() {
        let mut rb = RingBuffer::new(8);
        rb.push_slice(&[1.0, 2.0]);
        let out = rb.drain_n(10);
        assert_eq!(out, vec![1.0, 2.0]);
        assert!(rb.is_empty());
    }

    #[test]
    fn peek_last_does_not_drain() {
        let mut rb = RingBuffer::new(8);
        rb.push_slice(&[1.0, 2.0, 3.0, 4.0]);
        let peeked = rb.peek_last(2);
        assert_eq!(peeked, vec![3.0, 4.0]);
        assert_eq!(rb.len(), 4); // unchanged
    }

    #[test]
    fn peek_last_more_than_len() {
        let mut rb = RingBuffer::new(8);
        rb.push_slice(&[1.0, 2.0]);
        let peeked = rb.peek_last(10);
        assert_eq!(peeked, vec![1.0, 2.0]);
    }

    #[test]
    fn is_full() {
        let mut rb = RingBuffer::new(3);
        assert!(!rb.is_full());
        rb.push_slice(&[1.0, 2.0, 3.0]);
        assert!(rb.is_full());
        rb.push_slice(&[4.0]);
        assert!(rb.is_full());
        assert_eq!(rb.len(), 3);
    }

    #[test]
    fn multiple_push_drain_cycles() {
        let mut rb = RingBuffer::new(4);
        rb.push_slice(&[1.0, 2.0]);
        rb.drain_all();
        rb.push_slice(&[3.0, 4.0, 5.0]);
        let out = rb.drain_all();
        assert_eq!(out, vec![3.0, 4.0, 5.0]);
    }
}
