import SwiftUI

/// Settings section for optional remote inference providers. Lives under
/// Settings → Inference. Routes persist via `InferenceRoutes`; the API key
/// goes to the Keychain, never to UserDefaults or logs.
struct RemoteProvidersSection: View {
    @EnvironmentObject var loc: Localizer

    @State private var routes: [InferenceRoute] = []
    @State private var activeSelection = ""
    @State private var apiKey = ""
    @State private var keySet = false
    @State private var testState: TestState?

    private struct TestState: Equatable {
        var ok: Bool
        var message: String
    }

    var body: some View {
        Section(loc.t("Proveedor remoto (opcional)", "Remote provider (optional)")) {
            LabeledContent(loc.t("Ruta activa", "Active route")) {
                KestrelDropdown(selection: $activeSelection, options: routeOptions, width: 220)
            }
            .settingsGlyph("point.3.connected.trianglepath.dotted")
            .infoTip(loc.t("El motor local sigue siendo la opción por defecto: nada de esto lo toca. Una ruta remota envía el chat a un proveedor externo y funciona aunque el servidor local esté parado.",
                           "The local engine remains the default: none of this touches it. A remote route sends chat to an external provider and works even while the local server is stopped."))

            ForEach($routes) { $route in
                routeEditor($route)
            }

            Button(loc.t("Añadir proveedor", "Add provider"), systemImage: "plus") {
                routes.append(InferenceRoute(name: loc.t("Proveedor", "Provider"),
                                             dialect: .openAI, baseURL: "", modelID: ""))
                persist()
            }
            .buttonStyle(.borderless)

            if let testState {
                Label(testState.message,
                      systemImage: testState.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(testState.ok ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            keyRow
        }
        .onAppear {
            routes = InferenceRoutes.load()
            activeSelection = InferenceRoutes.activeID ?? ""
            keySet = !(Keychain.get("remote-api-key") ?? "").isEmpty
        }
        .onChange(of: activeSelection) { _, newValue in
            InferenceRoutes.setActive(newValue.isEmpty ? nil : newValue)
        }
    }

    private var routeOptions: [KestrelDropdown<String>.Option] {
        [.init(value: "", title: loc.t("Motor local", "Local engine"))]
            + routes.map { route in
                let label = route.name.isEmpty ? route.dialect.title.1 : route.name
                let ready = route.isConfigured ? "" : loc.t(" (incompleta)", " (incomplete)")
                return .init(value: route.id.uuidString, title: label + ready)
            }
    }

    @ViewBuilder private func routeEditor(_ route: Binding<InferenceRoute>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(loc.t("Nombre", "Name"), text: route.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.weight(.medium))
                    .onChange(of: route.wrappedValue.name) { _, _ in persist() }
                Picker("", selection: route.dialect) {
                    ForEach([InferenceDialect.openAI, .anthropic]) { dialect in
                        Text(loc.t(dialect.title.0, dialect.title.1)).tag(dialect)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
                Button(role: .destructive) {
                    routes.removeAll { $0.id == route.wrappedValue.id }
                    persist()
                } label: { Label(loc.t("Borrar", "Delete"), systemImage: "trash") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .tint(.red)
                    .accessibilityLabel(loc.t("Eliminar el proveedor", "Delete the provider"))
            }
            TextField(loc.t("https://proveedor.example.com/v1", "https://provider.example.com/v1"),
                      text: route.baseURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .onChange(of: route.wrappedValue.baseURL) { _, _ in persist() }
            HStack {
                TextField(loc.t("ID del modelo (lo pone el proveedor)", "Model id (from the provider)"),
                          text: route.modelID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled()
                    .onChange(of: route.wrappedValue.modelID) { _, _ in persist() }
                Button(loc.t("Probar", "Test")) { Task { await test(route.wrappedValue) } }
                    .buttonStyle(.borderless)
                    .disabled(!route.wrappedValue.isConfigured)
            }
        }
        .padding(.vertical, 2)
    }

    private var keyRow: some View {
        HStack {
            SecureField(loc.t("Clave API del proveedor", "Provider API key"), text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            Button(loc.t("Guardar clave", "Save key")) {
                let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    Keychain.delete("remote-api-key")
                    keySet = false
                } else {
                    Keychain.setThisDeviceOnly(trimmed, account: "remote-api-key")
                    keySet = true
                }
                apiKey = ""
            }
            .buttonStyle(.borderless)
            .disabled(apiKey.isEmpty && !keySet)
            if keySet {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel(loc.t("Clave guardada en el llavero", "Key stored in Keychain"))
            }
        }
        .infoTip(loc.t("La clave se guarda en el llavero del sistema y se envía solo al proveedor configurado. No se registra ni se sincroniza.",
                       "The key is stored in the system Keychain and sent only to the configured provider. It is never logged or synced."))
    }

    private func persist() {
        InferenceRoutes.save(routes)
    }

    private func test(_ route: InferenceRoute) async {
        guard let base = route.normalizedURL else {
            testState = TestState(ok: false, message: loc.t("URL no válida.", "Invalid URL."))
            return
        }
        let key = Keychain.get("remote-api-key") ?? ""
        var request: URLRequest
        if route.dialect == .anthropic {
            let path = base.path.hasSuffix("/v1") ? "/messages" : "/v1/messages"
            request = URLRequest(url: URL(string: base.absoluteString + path)!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            let probe: [String: Any] = ["model": route.modelID, "max_tokens": 1,
                                        "messages": [["role": "user", "content": "ping"]]]
            request.httpBody = try? JSONSerialization.data(withJSONObject: probe)
        } else {
            request = URLRequest(url: URL(string: base.absoluteString + "/models")!)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        }
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let head = String(data: data.prefix(160), encoding: .utf8) ?? ""
            if (200..<300).contains(status) {
                testState = TestState(ok: true, message: loc.t("Conexión correcta (%@).", "Connection OK (%@).", "\(status)"))
            } else {
                testState = TestState(ok: false, message: loc.t("El proveedor respondió %@: %@", "Provider answered %@: %@", "\(status)", head))
            }
        } catch {
            testState = TestState(ok: false, message: error.localizedDescription)
        }
    }
}
