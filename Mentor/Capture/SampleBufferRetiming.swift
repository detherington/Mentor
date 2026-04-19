import CoreMedia
import Foundation

extension CMSampleBuffer {
    /// Return a copy of this sample buffer with every PTS (and DTS,
    /// when present) shifted by `-offset`. Used by the capture
    /// coordinator's pause/resume machinery to close the wall-clock
    /// gap left by the paused window — samples arriving after resume
    /// land at PTS values that continue seamlessly from the last
    /// sample written before pause, so the encoded track has no
    /// freeze-frame gap.
    ///
    /// Passing `offset == .zero` returns `self` without copying —
    /// the hot path during an un-paused recording avoids allocation.
    /// Returns `nil` on the (uncommon) failure paths where
    /// `CMSampleBufferCreateCopyWithNewTiming` can't produce a valid
    /// buffer; callers then drop the frame rather than write a bogus
    /// sample.
    func retimed(by offset: CMTime) -> CMSampleBuffer? {
        guard offset.isValid, CMTimeCompare(offset, .zero) > 0 else {
            return self
        }

        // First pass: how many timing entries does this buffer have?
        // Video is usually 1, audio is often 1 "block" covering many
        // samples, but the API supports per-sample timing arrays too.
        var needed: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(
            self,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &needed
        )
        guard needed > 0 else { return nil }

        var timings = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(),
            count: needed
        )
        let status = CMSampleBufferGetSampleTimingInfoArray(
            self,
            entryCount: needed,
            arrayToFill: &timings,
            entriesNeededOut: nil
        )
        guard status == noErr else { return nil }

        for i in 0..<needed {
            if timings[i].presentationTimeStamp.isValid {
                timings[i].presentationTimeStamp = CMTimeSubtract(
                    timings[i].presentationTimeStamp, offset
                )
            }
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeSubtract(
                    timings[i].decodeTimeStamp, offset
                )
            }
            // `duration` is a delta — untouched by an offset shift.
        }

        var newBuffer: CMSampleBuffer?
        let copyStatus = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: self,
            sampleTimingEntryCount: needed,
            sampleTimingArray: timings,
            sampleBufferOut: &newBuffer
        )
        return copyStatus == noErr ? newBuffer : nil
    }
}
