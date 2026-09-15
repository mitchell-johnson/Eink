import SwiftUI
import PhotosUI

private let ink = Color(red: 0.13, green: 0.18, blue: 0.17)
private let paper = Color(red: 0.97, green: 0.96, blue: 0.92)
private let accent = Color(red: 0.86, green: 0.25, blue: 0.16)

struct StudioView: View {
    @EnvironmentObject private var studio: StudioModel
    @EnvironmentObject private var bluetooth: LabelBluetooth
    @State private var settingsPresented = false
    @State private var labelPickerPresented = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var tab = 0
    @State private var forgetConfirmation = false
    @State private var writeTask: Task<Void, Never>?
    @State private var writeMessage: String?
    @FocusState private var promptFocused: Bool

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        preview
                        composer
                        deviceCard
                    }.padding(20)
                }.background(paper).scrollDismissesKeyboard(.interactively)
                    .navigationTitle("Label Studio").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { promptFocused = false }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { settingsPresented = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Settings")
                        }
                    }
            }.tabItem { Label("Create", systemImage: "square.and.pencil") }.tag(0)
            NavigationStack {
                Group {
                    if studio.designs.isEmpty {
                        ContentUnavailableView("Your little collection", systemImage: "square.stack", description: Text("Generated and imported designs are saved here on your iPhone."))
                    } else {
                        List {
                            ForEach(studio.designs) { design in
                                Button { studio.open(design); tab = 0 } label: {
                                    HStack(spacing: 14) {
                                        if let image = studio.thumbnail(design) {
                                            Image(uiImage: image).resizable().interpolation(.none).scaledToFit().frame(width: 100, height: 75).background(.white).clipShape(RoundedRectangle(cornerRadius: 6))
                                        }
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(design.prompt).font(.headline).lineLimit(2)
                                            Text(design.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                        }.foregroundStyle(ink)
                                    }.padding(.vertical, 6)
                                }.disabled(bluetooth.isWriting || studio.isGenerating).swipeActions { Button("Delete", role: .destructive) { studio.delete(design) } }
                            }
                        }.scrollContentBackground(.hidden)
                    }
                }.background(paper).navigationTitle("Saved designs")
            }.tabItem { Label("Library", systemImage: "square.stack") }.tag(1)
        }.tint(accent)
            .sheet(isPresented: $settingsPresented) { SettingsView().environmentObject(studio) }
            .sheet(isPresented: $labelPickerPresented) { LabelPicker { id in startWrite(id) }.environmentObject(bluetooth) }
            .alert("Label Studio", isPresented: Binding(get: { studio.message != nil }, set: { if !$0 { studio.message = nil } })) { Button("OK") { studio.message = nil } } message: { Text(studio.message ?? "") }
            .alert("Start fresh?", isPresented: $forgetConfirmation) {
                Button("Keep request", role: .cancel) {}
                Button("Forget request", role: .destructive) { studio.forgetPending() }
            } message: { Text("Your server may still finish and charge for this generation. Forgetting it does not cancel that work.") }
            .onChange(of: selectedPhoto) { _, item in
                Task {
                    do { if let data = try await item?.loadTransferable(type: Data.self) { studio.importImage(data) } }
                    catch { studio.message = "The photo could not be loaded. Please try another image." }
                    selectedPhoto = nil
                }
            }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A small screen.\nAn open canvas.").font(.system(size: 32, weight: .semibold, design: .serif)).foregroundStyle(ink)
            HStack(spacing: 7) {
                ForEach([Color.black, .white, .yellow, .red], id: \.self) { color in Circle().fill(color).overlay(Circle().strokeBorder(ink.opacity(0.15))).frame(width: 13, height: 13) }
                Text("4.2″  ·  400 × 300  ·  Four colours").font(.caption).foregroundStyle(.secondary)
            }.accessibilityElement(children: .ignore).accessibilityLabel("4.2 inch display. 400 by 300 pixels. Black, white, yellow and red.")
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(.white)
                if let artwork = studio.artwork {
                    Image(uiImage: artwork.image).resizable().interpolation(.none).scaledToFit().accessibilityLabel("Prepared label artwork")
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles.rectangle.stack").font(.system(size: 36, weight: .light))
                        Text("Your next label starts here").font(.system(.headline, design: .serif))
                        Text("Describe a design below, or import an image.").font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }.foregroundStyle(ink).padding()
                }
            }.aspectRatio(4/3, contentMode: .fit).padding(12).background(Color(red: 0.88, green: 0.87, blue: 0.82), in: RoundedRectangle(cornerRadius: 20))
            HStack {
                Label("Exact pixel preview", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.secondary)
                Spacer()
                PhotosPicker(selection: $selectedPhoto, matching: .images) { Label("Import", systemImage: "photo") }.font(.caption.weight(.semibold)).disabled(studio.isGenerating || bluetooth.isWriting)
            }
            Text("Screen colours will look softer on e-paper. Images are fitted and converted to the label’s four inks.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What belongs on your label?").font(.headline).foregroundStyle(ink)
            ZStack(alignment: .topLeading) {
                if studio.prompt.isEmpty { Text("A sunny kitchen label reading ‘Fresh lemons’, with a bold lemon illustration…").foregroundStyle(.secondary).padding(.horizontal, 13).padding(.vertical, 16).allowsHitTesting(false) }
                TextEditor(text: $studio.prompt).focused($promptFocused).scrollContentBackground(.hidden).frame(minHeight: 110).padding(8).opacity(studio.prompt.isEmpty ? 0.8 : 1).accessibilityLabel("Design prompt")
            }.background(.white, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(ink.opacity(0.12)))
                .disabled(studio.pending != nil)
            if let _ = studio.pending {
                HStack(alignment: .top, spacing: 10) {
                    if studio.isGenerating { ProgressView().tint(accent) }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(studio.generationPhase).font(.subheadline.weight(.medium))
                        Text("Your request is saved. You can leave and resume without starting another generation.").font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityElement(children: .combine)
                HStack {
                    if studio.isGenerating { Button("Pause waiting") { studio.pause() } }
                    else {
                        Button("Resume request") { studio.resume() }.buttonStyle(.borderedProminent)
                        Spacer()
                        Button("Start fresh") { forgetConfirmation = true }.font(.subheadline)
                    }
                }
            } else {
                Button { promptFocused = false; studio.generate() } label: {
                    Label("Generate label", systemImage: "sparkles").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                }.buttonStyle(.borderedProminent).disabled(studio.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || studio.prompt.utf8.count > 4000 || bluetooth.isWriting)
                Text(studio.connected ? "GPT Image 2.5 · Uses your OpenAI account. Generation is a paid request." : "Connect your private server in Settings to generate.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: "antenna.radiowaves.left.and.right"); Text("Send to your label").font(.headline); Spacer() }.foregroundStyle(ink)
            if bluetooth.isWriting {
                Text(bluetooth.phase).font(.subheadline)
                ProgressView(value: bluetooth.progress).tint(accent)
                Text("Keep this app open and your iPhone close to the label. The display may flash while it refreshes.").font(.caption).foregroundStyle(.secondary)
                Button("Cancel transfer", role: .destructive) { bluetooth.cancel(); writeTask?.cancel() }
            } else {
                Text(writeMessage ?? "Writes directly over Bluetooth. No Android app or supplier service needed.").font(.subheadline).foregroundStyle(.secondary)
                Button {
                    do { _ = try LabelKeyStore().load(); labelPickerPresented = true }
                    catch { writeMessage = error.localizedDescription }
                } label: { Label("Choose label & write", systemImage: "arrow.up.right").frame(maxWidth: .infinity).padding(.vertical, 8) }.buttonStyle(.bordered).disabled(studio.artwork == nil || studio.isGenerating)
            }
        }.padding(18).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
    }

    private func startWrite(_ id: UUID) {
        guard let frame = studio.artwork?.frame else { return }
        labelPickerPresented = false
        writeMessage = nil
        writeTask = Task {
            do { _ = try await bluetooth.write(frame: frame, to: id); writeMessage = "Display updated. Your design will stay on the label without power." }
            catch { writeMessage = error.localizedDescription }
            writeTask = nil
        }
    }
}

struct LabelPicker: View {
    @EnvironmentObject private var bluetooth: LabelBluetooth
    @Environment(\.dismiss) private var dismiss
    let select: (UUID) -> Void
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose your 4.2-inch label. This replaces everything currently on its screen.")
                    Text("Labels sometimes advertise only every few minutes. Keep this screen open and your iPhone nearby.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Nearby labels") {
                    if bluetooth.labels.isEmpty {
                        HStack { if bluetooth.isScanning { ProgressView() }; Text(bluetooth.phase).font(.subheadline) }
                    }
                    ForEach(bluetooth.labels) { label in
                        Button { select(label.id) } label: {
                            HStack {
                                VStack(alignment: .leading) { Text(label.name).font(.headline); if let battery = label.batteryMillivolts { Text(String(format: "Battery %.2f V", Double(battery)/1000)).font(.caption).foregroundStyle(.secondary) } }
                                Spacer(); Label("Write", systemImage: "arrow.up.right")
                            }
                        }
                    }
                }
                if let error = bluetooth.error { Text(error).foregroundStyle(.red) }
                if !bluetooth.bluetoothAvailable {
                    Button("Open iPhone Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                }
            }.navigationTitle("Choose label").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }.tint(accent).onAppear { bluetooth.startScan() }.onDisappear { bluetooth.stopScan() }
    }
}
