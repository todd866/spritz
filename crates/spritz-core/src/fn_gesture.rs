#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FnAction {
    Tap,
    Start,
    Finish,
    Cancel,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum FnState {
    Idle,
    Pending(f64),
    Holding,
    Interrupted,
}

#[derive(Debug, Clone, Copy)]
pub struct FnGesture {
    pub state: FnState,
}

impl Default for FnGesture {
    fn default() -> Self {
        Self { state: FnState::Idle }
    }
}

impl FnGesture {
    pub const HOLD_DELAY_SECS: f64 = 0.30;

    pub fn press(&mut self, time: f64, modified: bool) {
        if self.state != FnState::Idle {
            return;
        }
        self.state = if modified {
            FnState::Interrupted
        } else {
            FnState::Pending(time)
        };
    }

    pub fn advance(&mut self, time: f64) -> Option<FnAction> {
        let FnState::Pending(down) = self.state else {
            return None;
        };
        if time < down {
            return self.interrupt();
        }
        if time - down < Self::HOLD_DELAY_SECS {
            return None;
        }
        self.state = FnState::Holding;
        Some(FnAction::Start)
    }

    pub fn release(&mut self, time: f64) -> Option<FnAction> {
        let prev = self.state;
        self.state = FnState::Idle;
        match prev {
            FnState::Pending(down) => {
                if time >= down && time - down < Self::HOLD_DELAY_SECS {
                    Some(FnAction::Tap)
                } else {
                    Some(FnAction::Cancel)
                }
            }
            FnState::Holding => Some(FnAction::Finish),
            _ => None,
        }
    }

    pub fn interrupt(&mut self) -> Option<FnAction> {
        match self.state {
            FnState::Pending(_) | FnState::Holding => {
                self.state = FnState::Interrupted;
                Some(FnAction::Cancel)
            }
            _ => None,
        }
    }

    pub fn reset(&mut self) -> Option<FnAction> {
        let act = self.interrupt();
        self.state = FnState::Idle;
        act
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tap_hold_and_interrupt_transitions() {
        let mut g = FnGesture::default();
        g.press(1.0, false);
        assert_eq!(g.advance(1.1), None);
        assert_eq!(g.release(1.2), Some(FnAction::Tap));
        assert_eq!(g.state, FnState::Idle);

        g.press(2.0, false);
        assert_eq!(g.advance(2.29), None);
        assert_eq!(g.advance(2.31), Some(FnAction::Start));
        assert_eq!(g.release(3.5), Some(FnAction::Finish));

        g.press(4.0, false);
        assert_eq!(g.interrupt(), Some(FnAction::Cancel));
        assert_eq!(g.release(4.1), None);

        g.press(5.0, true);
        assert_eq!(g.advance(5.5), None);
        assert_eq!(g.release(5.6), None);
    }
}
