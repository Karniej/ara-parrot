import Foundation

/// What `ara models list` prints, as a pure function of the registry and one
/// on-disk question per model.
///
/// A separate type from the subcommand for the reason every `*MenuModel` is:
/// `ara models list` is where a model gets picked, the pick decides whether
/// the next launch downloads 1.6 GB, and a column that says so is only useful
/// if it is right — which is a thing a test can check without a hub cache.
public enum ModelListing {
    /// - Parameter isPresent: whether this model's weights are already on
    ///   disk. Injected rather than read here so the listing can be checked
    ///   against both answers on a machine that has neither.
    public static func lines(models: [TranscriptionModel],
                             isPresent: (TranscriptionModel) -> Bool) -> [String] {
        models.map { model in
            let star = model.recommended ? "★" : " "
            let id = model.id.padding(toLength: 24, withPad: " ", startingAt: 0)
            let availability = ModelSize
                .availability(megabytes: model.sizeMB, downloaded: isPresent(model))
                .padding(toLength: 18, withPad: " ", startingAt: 0)
            let languages = "[\(model.languages.joined(separator: ","))]"
                .padding(toLength: 9, withPad: " ", startingAt: 0)
            return "\(star) \(id) \(availability) \(languages) \(model.displayName)"
        }
    }
}
