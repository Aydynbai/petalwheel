import AppKit

/// Opens the interactive editor for a tool.
@MainActor
enum EditorRouter {
    static func present(_ tool: FileTool, inputs: [URL], completion: @escaping EditorCompletion) {
        switch tool {
        case .annotateImage: AnnotateEditor.present(inputs: inputs, completion: completion)
        case .redactImage: RedactImageEditor.present(inputs: inputs, completion: completion)
        case .adjustImage: AdjustImageEditor.present(inputs: inputs, completion: completion)
        case .organizePDF: OrganizePDFEditor.present(inputs: inputs, completion: completion)
        case .trimMedia: TrimEditor.present(inputs: inputs, completion: completion)
        case .bleepAudio: BleepEditor.present(inputs: inputs, completion: completion)
        case .redactVideo: RedactVideoEditor.present(inputs: inputs, completion: completion)
        default: completion(nil)
        }
    }
}
