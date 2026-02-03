import SwiftUI
import CoreLocation
import MapKit
import PhotosUI
import UIKit

#if canImport(CloudKit)
import CloudKit
#endif

/// Add a new Spot.
///
/// Key UX requirement:
/// - user can place the spot by **dragging the pin** or tapping the map.
/// - optional photo via PhotosPicker or Camera.
struct AddSpotView: View {
    let initialCoordinate: CLLocationCoordinate2D
    let onAdd: (String, String, CLLocationCoordinate2D, Data?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var note: String = ""

    @State private var selectedCoordinate: CLLocationCoordinate2D
    @State private var mapRegion: MKCoordinateRegion

    @State private var photoData: Data? = nil
    @State private var pickedItem: PhotosPickerItem? = nil
    @State private var showCamera: Bool = false

    init(initialCoordinate: CLLocationCoordinate2D,
         onAdd: @escaping (String, String, CLLocationCoordinate2D, Data?) -> Void) {
        self.initialCoordinate = initialCoordinate
        self.onAdd = onAdd
        _selectedCoordinate = State(initialValue: initialCoordinate)
        _mapRegion = State(initialValue: MKCoordinateRegion(
            center: initialCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("addspot.place_pin_help")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        DraggablePinMap(coordinate: $selectedCoordinate, region: $mapRegion)
                            .frame(height: 230)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        HStack {
                            Button {
                                // jump pin to current visible center
                                selectedCoordinate = mapRegion.center
                            } label: {
                                Label("addspot.use_map_center", systemImage: "mappin.and.ellipse")
                            }

                            Spacer()

                            Button {
                                // recenter map on the pin
                                mapRegion.center = selectedCoordinate
                            } label: {
                                Label("addspot.recenter", systemImage: "location")
                            }
                        }
                        .font(.subheadline)

                        Text("addspot.coordinates \(String(format: "%.6f", selectedCoordinate.latitude)) \(String(format: "%.6f", selectedCoordinate.longitude))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("addspot.section_location")
                }

                Section("addspot.section_spot") {
                    TextField("addspot.name", text: $title)
                        .textInputAutocapitalization(.words)

                    TextField("addspot.note", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("addspot.section_photo") {
                    HStack(spacing: 12) {
                        PhotosPicker(selection: $pickedItem, matching: .images) {
                            Label("addspot.choose_photo", systemImage: "photo")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            showCamera = true
                        } label: {
                            Label("addspot.take_photo", systemImage: "camera")
                        }
                        .buttonStyle(.bordered)
                    }

                    if let photoData,
                       let uiImage = UIImage(data: photoData) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 84, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))

                            VStack(alignment: .leading, spacing: 6) {
                                Text("addspot.photo_added")
                                    .font(.subheadline.weight(.semibold))
                                Text("addspot.photo_added_help")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Button(role: .destructive) {
                                    self.photoData = nil
                                    self.pickedItem = nil
                                } label: {
                                    Label("addspot.remove_photo", systemImage: "trash")
                                }
                                .font(.caption)
                            }
                        }
                    } else {
                        Text("addspot.photo_optional")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("addspot.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("addspot.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("addspot.save") {
                        onAdd(clean(title), clean(note), selectedCoordinate, photoData)
                        dismiss()
                    }
                    .disabled(clean(title).isEmpty)
                }
            }
        }
        .onChange(of: pickedItem) { _, newValue in
            guard let item = newValue else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run { self.photoData = data }
                }
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker(imageData: $photoData)
                .ignoresSafeArea()
        }
    }

    private func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}


// MARK: - Map + Camera helpers

struct DraggablePinMap: UIViewRepresentable {
    @Binding var coordinate: CLLocationCoordinate2D
    @Binding var region: MKCoordinateRegion

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.isRotateEnabled = true
        map.isPitchEnabled = false
        map.showsUserLocation = true
        map.setRegion(region, animated: false)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        map.addGestureRecognizer(tap)

        context.coordinator.setAnnotation(on: map, coordinate: coordinate)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Keep map region and pin in sync.
        if map.region.center.latitude != region.center.latitude || map.region.center.longitude != region.center.longitude {
            map.setRegion(region, animated: true)
        }
        context.coordinator.setAnnotation(on: map, coordinate: coordinate)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: DraggablePinMap
        private let pin = MKPointAnnotation()

        init(_ parent: DraggablePinMap) { self.parent = parent }

        func setAnnotation(on map: MKMapView, coordinate: CLLocationCoordinate2D) {
            if map.annotations.filter({ $0 is MKPointAnnotation }).isEmpty {
                pin.coordinate = coordinate
                map.addAnnotation(pin)
            } else {
                if abs(pin.coordinate.latitude - coordinate.latitude) > 0.000001 ||
                    abs(pin.coordinate.longitude - coordinate.longitude) > 0.000001 {
                    pin.coordinate = coordinate
                }
            }
        }

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            guard let map = gr.view as? MKMapView else { return }
            let point = gr.location(in: map)
            parent.coordinate = map.convert(point, toCoordinateFrom: map)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            let id = "pin"
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            v.isDraggable = true
            v.canShowCallout = false
            return v
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.region = mapView.region
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                     didChange newState: MKAnnotationView.DragState,
                     fromOldState oldState: MKAnnotationView.DragState) {
            guard let ann = view.annotation else { return }
            if newState == .ending || newState == .canceling {
                parent.coordinate = ann.coordinate
                view.setDragState(.none, animated: true)
            }
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    @Binding var imageData: Data?

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let image = (info[.originalImage] as? UIImage)
            if let image, let data = image.jpegData(compressionQuality: 0.85) {
                parent.imageData = data
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
