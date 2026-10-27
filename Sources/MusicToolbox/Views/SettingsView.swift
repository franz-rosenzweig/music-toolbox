import SwiftUI

/// Where the server is. Saved only when Connect is pressed, so half a typed address never counts as signed in.
struct SettingsForm: View {
    var firstRun = false

    @AppStorage("panelURL") private var storedURL = ""
    @AppStorage("panelUser") private var storedUser = ""
    @AppStorage("sshTarget") private var storedSSH = ""
    @AppStorage("musicPath") private var storedMusic = ""
    @AppStorage("ripsFolder") private var storedRips = ""

    @State private var url = ""
    @State private var user = ""
    @State private var password = ""
    @State private var ssh = ""
    @State private var music = ""
    @State private var rips = ""
    @State private var panelResult: String?
    @State private var sshResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("Panel") {
                TextField("Server", text: $url, prompt: Text("https://…"))
                TextField("User", text: $user)
                SecureField("Password", text: $password)
                if let r = panelResult { status(r, ok: r == "Connected") }
            }
            Section("Copy to devices") {
                TextField("SSH", text: $ssh, prompt: Text("user@host"))
                TextField("Music folder", text: $music, prompt: Text("/srv/media/music"))
                if let r = sshResult { status(r, ok: r == "Connected") }
            }
            Section("Rip") {
                TextField("Rips folder", text: $rips, prompt: Text("~/Music/CD Rips"))
            }
            Section {
                HStack {
                    Spacer()
                    if testing { ProgressView().controlSize(.small) }
                    Button("Connect") { Task { await connect() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(testing || url.isEmpty || user.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            url = storedURL; user = storedUser; password = Keychain.get("panel") ?? ""
            ssh = storedSSH; music = storedMusic; rips = storedRips
        }
    }

    private func status(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .red)
    }

    private func connect() async {
        testing = true
        defer { testing = false }
        Keychain.set(password, for: "panel")
        storedURL = url; storedUser = user; storedSSH = ssh; storedMusic = music; storedRips = rips
        panelResult = nil
        sshResult = nil
        if let panel = Config.panel {
            do {
                try await panel.health()
                _ = try await panel.devices()
                panelResult = "Connected"
                await DeviceStore.shared.loadProfiles()
            } catch let e as PanelError { panelResult = e.label } catch { panelResult = "Failed" }
        } else {
            panelResult = "Not a valid address"
        }
        if let remote = Config.remote {
            let o = try? await remote.run("test -d \(Remote.quote(remote.musicPath))")
            sshResult = o == nil ? "Can’t run ssh" : o!.status == 0 ? "Connected" : o!.status == 255 ? DeviceSession.describe(RemoteError(o!.errText)) : "Music folder not found"
        }
    }
}
