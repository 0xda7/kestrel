import SwiftUI

/// Settings section for optional remote inference providers. Lives under
/// Settings → Inference. Routes persist via `InferenceRoutes`; the API key
/// goes to the local 0600 secret store (never UserDefaults or logs, and no
/// longer the Keychain — its ad-hoc ACL prompted for the Mac password after
/// every rebuild).
struct RemoteProvidersSection: View {
    @EnvironmentObject var loc: Localizer

    @State private var routes: [InferenceRoute] = []
    @State private var activeSelection = ""
    @State private var testState: TestState?

    /// Per-route SecureField text, keyed by route id (the shared key field is
    /// gone: each provider carries its own credential).
    @State private var routeKeyDrafts: [String: String] = [:]
    @State private var routesWithKeys: Set<String> = []

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

            if activeSelection.isEmpty && !routes.isEmpty {
                Label(loc.t("Sin ruta activa: el chat responde con el motor local aunque los proveedores estén configurados.",
                            "No active route: chat answers with the local engine even though providers are configured."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if InferenceRoutes.legacySharedKeyPresent {
                Label(loc.t("Los proveedores sin clave propia usan la clave compartida heredada; guarda una clave por proveedor para migrarla.",
                            "Providers without their own key fall back to the inherited shared key; save a per-provider key to migrate off it."),
                      systemImage: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            routes = InferenceRoutes.load()
            activeSelection = InferenceRoutes.activeID ?? ""
            routesWithKeys = Set(routes.filter { InferenceRoutes.hasAPIKey(for: $0) }
                .map(\.id.uuidString))
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
            routeKeyRow(route.wrappedValue)
        }
        .padding(.vertical, 2)
    }

    /// One credential per provider, stored under its own file in the local
    /// secret store. Empty input + an existing key = clear the key (Save acts
    /// as Delete).
    @ViewBuilder private func routeKeyRow(_ route: InferenceRoute) -> some View {
        let id = route.id.uuidString
        let hasKey = routesWithKeys.contains(id)
        HStack {
            SecureField(loc.t("Clave API de este proveedor", "API key for this provider"),
                        text: Binding(
                            get: { routeKeyDrafts[id] ?? "" },
                            set: { routeKeyDrafts[id] = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            Button(loc.t("Guardar clave", "Save key")) {
                let trimmed = (routeKeyDrafts[id] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                InferenceRoutes.setAPIKey(trimmed, for: route)
                if trimmed.isEmpty { routesWithKeys.remove(id) }
                else { routesWithKeys.insert(id) }
                routeKeyDrafts[id] = ""
                PiBridge.sync()
                LatchBridge.sync()
            }
            .buttonStyle(.borderless)
            .disabled((routeKeyDrafts[id] ?? "").isEmpty && !hasKey)
            if hasKey {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel(loc.t("Clave guardada", "Key stored"))
            }
        }
        .infoTip(loc.t("La clave se guarda cifrada solo en este Mac (almacén local de secretos de Kestrel), asociada solo a este proveedor, y se envía únicamente a él. No se registra ni se sincroniza.",
                       "The key is stored on this Mac only (Kestrel's local secret store), scoped to this provider only, and sent only to it. It is never logged or synced."))
    }

    private func persist() {
        InferenceRoutes.save(routes)
        // The sidecars' provider configs follow Kestrel's routes; a stale
        // entry there is how chat ended up answering through a provider the
        // user never picked.
        PiBridge.sync()
        LatchBridge.sync()
    }

    private func test(_ route: InferenceRoute) async {
        guard let base = route.normalizedURL else {
            testState = TestState(ok: false, message: loc.t("URL no válida.", "Invalid URL."))
            return
        }
        let key = InferenceRoutes.apiKey(for: route)
        var request: URLRequest
        if route.dialect == .anthropic {
            let path = base.path.hasSuffix("/v1") ? "/messages" : "/v1/messages"
            request = URLRequest(url: URL(string: base.absoluteString + path)
                                 ?? URL(fileURLWithPath: "/dev/null"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            let probe: [String: Any] = ["model": route.modelID, "max_tokens": 1,
                                        "messages": [["role": "user", "content": "ping"]]]
            request.httpBody = try? JSONSerialization.data(withJSONObject: probe)
        } else {
            request = URLRequest(url: URL(string: base.absoluteString + "/models")
                                 ?? URL(fileURLWithPath: "/dev/null"))
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
