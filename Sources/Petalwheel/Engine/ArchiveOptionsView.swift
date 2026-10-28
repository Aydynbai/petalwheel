import SwiftUI

// Tool options panel controls for the archive tools (Make Archive, Compress File, password prompt).

extension ToolOptionsModel {
    /// Called from init: never prefill a password, and keep the format valid for the tool.
    func prepareArchiveOptions() {
        switch tool {
        case .extractArchive, .testArchive, .listArchive:
            // A non-nil initial password is the one that just failed (see ArchivePrompts.askPassword).
            archivePasswordWasWrong = options.archivePassword != nil
            options.archivePassword = nil
        case .createArchive:
            options.archivePassword = nil
            if !ArchiveSupport.createFormats.contains(options.archiveFormat) { options.archiveFormat = .zip }
        case .compressSingle:
            options.archivePassword = nil
            if !ArchiveSingleFile.writableFormats.contains(options.archiveFormat) { options.archiveFormat = .gz }
        default:
            break
        }
    }

    var archivePasswordText: Binding<String> {
        Binding(get: { self.options.archivePassword ?? "" },
                set: { self.options.archivePassword = $0.isEmpty ? nil : $0 })
    }
}

extension ToolOptionsView {
    var archiveControls: some View {
        VStack(alignment: .leading, spacing: KQTheme.spacing) {
            OptionRow("Format") {
                Picker("", selection: $model.options.archiveFormat) {
                    ForEach(ArchiveSupport.createFormats) { Text(verbatim: $0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 140)
            }
            if model.options.archiveFormat == .zip || model.options.archiveFormat == .sevenZ {
                OptionRow("Compression") {
                    Picker("", selection: $model.options.archiveLevel) {
                        Text("Fast").tag(1)
                        Text("Normal").tag(6)
                        Text("Best").tag(9)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            if model.options.archiveFormat == .zip {
                OptionRow("Password (optional)") {
                    SecureField("No password", text: model.archivePasswordText)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Encrypted with AES-256. Windows Explorer can't open such zips: use 7-Zip or Petalwheel.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(archiveFormatNote)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var archiveFormatNote: String {
        switch model.options.archiveFormat {
        case .dmg: return L("A compressed disk image that opens on any Mac.")
        case .iso: return L("A disc image that opens on Mac, Windows and Linux.")
        case .sevenZ: return L("Smallest files. Opens with 7-Zip, The Unarchiver or Petalwheel.")
        default: return L("Only zip archives can have a password.")
        }
    }

    var compressFileControls: some View {
        VStack(alignment: .leading, spacing: KQTheme.spacing) {
            OptionRow("Format") {
                Picker("", selection: $model.options.archiveFormat) {
                    ForEach(ArchiveSingleFile.writableFormats) { Text(verbatim: "." + $0.fileExtension).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text("Each file is compressed on its own, next to the original. gz opens everywhere, xz and zst are smaller.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var archivePasswordControls: some View {
        VStack(alignment: .leading, spacing: KQTheme.spacing) {
            Text("This archive is password-protected. Enter its password.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            if model.archivePasswordWasWrong {
                Label(L("Wrong password. Try again."), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(KQTheme.danger)
            }
            SecureField("Password", text: model.archivePasswordText)
                .textFieldStyle(.roundedBorder)
        }
    }
}
