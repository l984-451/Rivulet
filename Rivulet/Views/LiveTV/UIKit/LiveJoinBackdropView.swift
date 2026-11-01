import UIKit

/// What the join screen shows for a channel: the guide's artwork and summary
/// for the programme on now, so a slow tune is not a black screen.
struct LiveJoinBackdropContent: Equatable {
    let artworkURL: URL?
    let title: String
    let summary: String?

    /// Nil when the guide has nothing on this channel: the screen stays plain.
    static func make(program: UnifiedProgram?) -> LiveJoinBackdropContent? {
        guard let program else { return nil }
        let summary = program.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LiveJoinBackdropContent(
            artworkURL: GuideLayoutView.backdropURL(for: program),
            title: program.title,
            summary: (summary?.isEmpty ?? true) ? nil : summary)
    }
}

/// Artwork, title and summary behind the join spinner, like the pause screen.
final class LiveJoinBackdropView: UIView {
    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let summaryLabel = UILabel()
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        let scrim = CAGradientLayer()
        scrim.colors = [UIColor.black.withAlphaComponent(0.35).cgColor,
                        UIColor.black.withAlphaComponent(0.85).cgColor]
        let scrimView = LiveJoinScrimView(layer: scrim)
        scrimView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrimView)

        titleLabel.font = .systemFont(ofSize: 48, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        summaryLabel.font = .systemFont(ofSize: 29, weight: .regular)
        summaryLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        summaryLabel.numberOfLines = 4
        let stack = UIStackView(arrangedSubviews: [titleLabel, summaryLabel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrimView.topAnchor.constraint(equalTo: topAnchor),
            scrimView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrimView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrimView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MediaRowMetrics.rowLeading),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MediaRowMetrics.rowLeading),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -120)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ content: LiveJoinBackdropContent?) {
        loadTask?.cancel()
        imageView.image = nil
        guard let content else { isHidden = true; return }
        titleLabel.text = content.title
        summaryLabel.text = content.summary
        isHidden = false
        guard let url = content.artworkURL else { return }
        loadTask = Task { @MainActor [weak self] in
            let image = await ImageCacheManager.shared.image(for: url, quality: .full)
            guard let self, !Task.isCancelled else { return }
            self.imageView.image = image
        }
    }

    func hide() {
        loadTask?.cancel()
        loadTask = nil
        isHidden = true
        imageView.image = nil
    }
}

/// A view whose backing layer is the given gradient's configuration.
private final class LiveJoinScrimView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    init(layer template: CAGradientLayer) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        (layer as? CAGradientLayer)?.colors = template.colors
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The join spinner, reporting when it starts and stops so the backdrop follows it.
final class LiveJoinSpinner: UIActivityIndicatorView {
    var onChange: ((Bool) -> Void)?
    override func startAnimating() { super.startAnimating(); onChange?(true) }
    override func stopAnimating() { super.stopAnimating(); onChange?(false) }
}
