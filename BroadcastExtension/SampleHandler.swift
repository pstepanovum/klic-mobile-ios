import LiveKit

#if os(iOS)
/// ReplayKit broadcast upload extension entry point. LKSampleHandler (LiveKit SDK) does all the
/// work: it opens the IPC socket to the app over the shared App Group and forwards the captured
/// screen sample buffers into the live LiveKit room, where the SDK publishes them as the local
/// participant's screen-share track. No custom logic needed beyond enabling logging.
@available(macCatalyst 13.1, *)
class SampleHandler: LKSampleHandler {
    override var enableLogging: Bool { true }
}
#endif
