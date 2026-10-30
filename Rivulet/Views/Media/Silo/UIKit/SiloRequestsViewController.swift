import UIKit

@MainActor
private final class SiloRequestCell: UITableViewCell {
    static let reuseIdentifier = "SiloRequestCell"
    private let platter = MusicFocusPlatterView()
    private let mediaIcon = UIImageView()
    private let kindLabel = UILabel()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let actionLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private var showsFocus = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        focusStyle = .custom
        clipsToBounds = false
        contentView.clipsToBounds = false
        titleLabel.font = .systemFont(ofSize: 31, weight: .semibold)
        kindLabel.font = .systemFont(ofSize: 23)
        statusLabel.font = .systemFont(ofSize: 25, weight: .medium)
        actionLabel.font = .systemFont(ofSize: 21)
        statusLabel.textAlignment = .right
        actionLabel.textAlignment = .right
        [kindLabel, titleLabel, statusLabel, actionLabel].forEach {
            $0.numberOfLines = 1
            $0.lineBreakMode = .byTruncatingTail
        }
        mediaIcon.contentMode = .scaleAspectFit
        mediaIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        chevron.contentMode = .scaleAspectFit
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        [platter, mediaIcon, titleLabel, kindLabel, statusLabel, actionLabel, chevron].forEach(contentView.addSubview)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("Use init(style:reuseIdentifier:)") }

    func configure(type: SiloRequestMediaType, kind: String, title: String, status: String, action: String) {
        mediaIcon.image = UIImage(systemName: type == .series ? "tv" : "film")
        kindLabel.text = kind
        titleLabel.text = title
        statusLabel.text = status
        actionLabel.text = action
        accessibilityLabel = "\(title), \(kind), \(status)"
        accessibilityHint = action
        updateAppearance()
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        showsFocus = false
        platter.alpha = 0
        updateAppearance()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let outset = MusicTrackRowCell.platterOutset
        let bounds = contentView.bounds.insetBy(dx: outset, dy: 0)
        platter.frame = bounds.insetBy(dx: -outset, dy: 6)
        mediaIcon.frame = CGRect(x: bounds.minX, y: 0, width: 40, height: bounds.height)
        chevron.frame = CGRect(x: bounds.maxX - 16, y: 0, width: 16, height: bounds.height)
        let statusWidth = min(420, bounds.width * 0.36)
        let statusX = chevron.frame.minX - 24 - statusWidth
        let textX: CGFloat = bounds.minX + 64
        let titleHeight = ceil(titleLabel.font.lineHeight)
        let detailHeight = ceil(kindLabel.font.lineHeight)
        let top = (bounds.height - titleHeight - detailHeight - 4) / 2
        titleLabel.frame = CGRect(x: textX, y: top, width: max(0, statusX - textX - 32), height: titleHeight)
        kindLabel.frame = CGRect(x: textX, y: titleLabel.frame.maxY + 4,
                                 width: titleLabel.bounds.width, height: detailHeight)
        statusLabel.frame = CGRect(x: statusX, y: top, width: statusWidth, height: titleHeight)
        actionLabel.frame = CGRect(x: statusX, y: kindLabel.frame.minY, width: statusWidth, height: detailHeight)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        showsFocus = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: showsFocus) { self.updateAppearance() }
    }

    private func updateAppearance() {
        platter.alpha = showsFocus ? 1 : 0
        titleLabel.textColor = .white
        statusLabel.textColor = UIColor(white: 1, alpha: showsFocus ? 1 : 0.85)
        let secondary = UIColor(white: 1, alpha: showsFocus ? 0.85 : 0.5)
        kindLabel.textColor = secondary
        actionLabel.textColor = secondary
        mediaIcon.tintColor = secondary
        chevron.tintColor = secondary
    }
}

/// Standalone Requests route. Present in a navigation controller or push onto an existing stack.
@MainActor final class SiloRequestsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    enum Context { case list, search(String) }

    private let service: SiloRequests
    private let providerID: String
    private let authorityRevision: UInt64
    private let context: Context
    private let ownerOverride: (@MainActor @Sendable () -> Bool)?
    private let searchBar = UISearchBar()
    private let table = UITableView(frame: .zero, style: .plain)
    private let sectionLabel = UILabel()
    private let stateRow = UIStackView()
    private let stateIcon = UIImageView()
    private let message = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retryButton = FocusableActionButton.pill(title: "Retry", systemImage: "arrow.clockwise").button
    private let refreshButton = FocusableActionButton.pill(title: "Refresh", systemImage: "arrow.clockwise").button
    private let mineButton = FocusableActionButton.pill(title: "Your requests", systemImage: "list.bullet").button
    private let pageSpinner = UIActivityIndicatorView(style: .medium)
    private var retryNextPage = false
    private var records: [SiloRequestRecord] = []
    private var results: [SiloRequestSearchResult] = []
    private var capability: SiloRequestsCapability?
    private var activeSearchQuery: String?
    private var modeSearch: Bool { activeSearchQuery != nil }
    private var loadTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var generation = 0
    private var nextSearchPage: Int?
    private var loadingNextPage = false

    init(provider: SiloProvider, context: Context = .list,
         ownerIsCurrent: (@MainActor @Sendable () -> Bool)? = nil) {
        if let ownerIsCurrent {
            service = SiloRequests(provider: provider, ownerIsCurrent: { await ownerIsCurrent() })
        } else {
            service = SiloRequests(provider: provider)
        }
        ownerOverride = ownerIsCurrent
        providerID = provider.id
        authorityRevision = provider.authorityRevision
        self.context = context
        super.init(nibName: nil, bundle: nil)
        if case let .search(query) = context {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            activeSearchQuery = trimmed.isEmpty ? nil : trimmed
        }
    }
    required init?(coder: NSCoder) { fatalError("Use init(provider:context:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Requests"
        view.backgroundColor = .black
        let heading = UILabel()
        heading.text = "Requests"
        heading.font = .systemFont(ofSize: 57, weight: .bold)
        heading.textColor = .white
        navigationItem.title = ""
        let description = UILabel()
        description.text = "Silo · Find something new and track your requests."
        description.font = .systemFont(ofSize: 25)
        description.textColor = UIColor(white: 1, alpha: 0.6)
        description.numberOfLines = 0
        searchBar.placeholder = "Search movies and series"
        searchBar.overrideUserInterfaceStyle = .dark
        searchBar.tintColor = .white
        searchBar.searchBarStyle = .minimal
        searchBar.delegate = self
        searchBar.accessibilityIdentifier = "silo.requests.search"
        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.delegate = self
        table.register(SiloRequestCell.self, forCellReuseIdentifier: SiloRequestCell.reuseIdentifier)
        table.backgroundColor = .clear
        table.rowHeight = 118
        table.contentInsetAdjustmentBehavior = .never
        table.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 40, right: 0)
        table.clipsToBounds = true
        table.remembersLastFocusedIndexPath = true
        table.accessibilityIdentifier = "silo.requests.list"
        sectionLabel.font = .systemFont(ofSize: 31, weight: .semibold)
        sectionLabel.textColor = UIColor(white: 1, alpha: 0.6)
        sectionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        message.numberOfLines = 0
        message.font = .systemFont(ofSize: 25)
        message.textColor = UIColor(white: 1, alpha: 0.7)
        message.accessibilityIdentifier = "silo.requests.state"
        spinner.color = .white
        spinner.hidesWhenStopped = true
        stateIcon.contentMode = .scaleAspectFit
        stateIcon.tintColor = UIColor(white: 1, alpha: 0.65)
        stateIcon.translatesAutoresizingMaskIntoConstraints = false
        stateIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 25)
        stateRow.axis = .horizontal
        stateRow.alignment = .center
        stateRow.spacing = 20
        [spinner, stateIcon, message, retryButton].forEach(stateRow.addArrangedSubview)
        retryButton.accessibilityIdentifier = "silo.requests.retry"
        refreshButton.accessibilityIdentifier = "silo.requests.refresh"
        mineButton.accessibilityIdentifier = "silo.requests.mine"
        retryButton.onPrimaryAction = { [weak self] in self?.retry() }
        refreshButton.onPrimaryAction = { [weak self] in self?.refresh() }
        mineButton.onPrimaryAction = { [weak self] in
            guard let self, mutationTask == nil else { return }
            searchBar.text = nil
            activeSearchQuery = nil
            searchBar.resignFirstResponder()
            refresh()
        }
        let toolbar = UIStackView(arrangedSubviews: [sectionLabel, UIView(), mineButton, refreshButton])
        toolbar.axis = .horizontal
        toolbar.alignment = .center
        toolbar.spacing = 24
        let header = UIStackView(arrangedSubviews: [heading, description, searchBar, toolbar, stateRow])
        header.axis = .vertical
        header.spacing = 20
        header.setCustomSpacing(8, after: heading)
        header.setCustomSpacing(28, after: description)
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(table)
        let margin = MediaRowMetrics.rowLeading
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            table.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            table.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        pageSpinner.color = .white
        pageSpinner.hidesWhenStopped = true
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 60))
        pageSpinner.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(pageSpinner)
        NSLayoutConstraint.activate([
            pageSpinner.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            pageSpinner.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        table.tableFooterView = footer
        if case let .search(query) = context { searchBar.text = query }
        updateSection()
    }

    deinit { loadTask?.cancel(); mutationTask?.cancel() }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    private var ownsCurrentProfile: Bool {
        if let ownerOverride { return ownerOverride() }
        guard let provider = SiloSession.storedProvider() else { return false }
        return provider.id == providerID && provider.authorityRevision == authorityRevision
    }

    private func updateSection() {
        if modeSearch {
            let query = activeSearchQuery ?? ""
            sectionLabel.text = "Results for “\(query)” · \(results.count)"
        } else {
            sectionLabel.text = "Your requests · \(records.count)"
        }
        mineButton.isHidden = !modeSearch
    }

    private func showState(_ text: String?, symbol: String = "info.circle",
                           loading: Bool = false, canRetry: Bool = false) {
        message.text = text
        stateRow.isHidden = text == nil
        stateIcon.image = UIImage(systemName: symbol)
        stateIcon.isHidden = loading
        if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        retryButton.isHidden = !canRetry
    }

    private func retry() {
        if retryNextPage { loadMoreSearchResults() } else { refresh() }
    }

    private func unavailableMessage(_ status: SiloRequestsCapability) -> String {
        if !status.requestsEnabled { return "Requests are disabled on this Silo server." }
        if status.allowed == false { return "This Silo profile does not have access to Requests." }
        if status.allowed == nil { return "Silo has not confirmed Requests access for this profile." }
        return "Requests are not currently available on this Silo server."
    }

    private func failureMessage(_ error: Error) -> String {
        guard let providerError = error as? MediaProviderError else { return error.localizedDescription }
        switch providerError {
        case .unreachable: return "Check your connection to the Silo server and try again."
        case .unauthorized: return "Sign in to Silo again to continue."
        case .notFound: return "This request or title is no longer available on Silo."
        case .backendSpecific(let message): return message
        case .transcodeRequired, .notPlayable: return "This action is not available for this title."
        }
    }

    func invalidateAuthority() {
        generation += 1
        loadTask?.cancel()
        mutationTask?.cancel()
        if let presented = presentedViewController { presented.dismiss(animated: false) }
        records = []; results = []; capability = nil; nextSearchPage = nil
        if isViewLoaded {
            table.reloadData()
            pageSpinner.stopAnimating()
            searchBar.isUserInteractionEnabled = false
            refreshButton.isHidden = true
            mineButton.isHidden = true
            showState("Requests are unavailable for this profile. Return to Silo and choose your active profile.")
        }
    }

    /// Call after returning from another route or when account/profile changes.
    func refresh() {
        guard ownsCurrentProfile else { invalidateAuthority(); return }
        guard mutationTask == nil else { return }
        generation += 1
        let current = generation
        let query = activeSearchQuery
        loadTask?.cancel()
        nextSearchPage = nil
        loadingNextPage = false
        records = []; results = []; capability = nil
        table.reloadData()
        pageSpinner.stopAnimating()
        retryNextPage = false
        refreshButton.isHidden = false
        searchBar.isUserInteractionEnabled = true
        updateSection()
        showState(modeSearch ? "Searching Silo…" : "Loading your requests…", loading: true)
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await service.status()
                guard current == generation else { return }
                guard ownsCurrentProfile else { invalidateAuthority(); return }
                capability = status
                guard status.isAvailable else {
                    records = []; results = []; table.reloadData()
                    searchBar.isUserInteractionEnabled = false
                    updateSection()
                    showState(unavailableMessage(status))
                    return
                }
                if let query {
                    let page = try await service.search(query)
                    guard current == generation else { return }
                    guard ownsCurrentProfile else { invalidateAuthority(); return }
                    results = page.results
                    nextSearchPage = page.page < page.totalPages ? page.page + 1 : nil
                } else {
                    let latest = try await service.mine()
                    guard current == generation else { return }
                    guard ownsCurrentProfile else { invalidateAuthority(); return }
                    records = latest
                }
                table.reloadData()
                updateSection()
                if modeSearch && results.isEmpty {
                    showState("No titles found. Try another movie or series name.", symbol: "magnifyingglass")
                } else if !modeSearch && records.isEmpty {
                    showState("No requests yet. Search for a movie or series to get started.", symbol: "tray")
                } else {
                    showState(nil)
                }
            } catch {
                guard current == generation else { return }
                if !ownsCurrentProfile { invalidateAuthority(); return }
                showState("Couldn’t load Requests. " + failureMessage(error),
                          symbol: "exclamationmark.triangle", canRetry: true)
            }
            spinner.stopAnimating()
        }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        guard mutationTask == nil else { searchBar.resignFirstResponder(); return }
        let query = (searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        activeSearchQuery = query.isEmpty ? nil : query
        searchBar.resignFirstResponder()
        refresh()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .playPause }) { retry(); return }
        super.pressesBegan(presses, with: event)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { modeSearch ? results.count : records.count }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if modeSearch && !retryNextPage && indexPath.row >= results.count - 5 { loadMoreSearchResults() }
    }

    private func loadMoreSearchResults() {
        guard ownsCurrentProfile, mutationTask == nil, !loadingNextPage, let page = nextSearchPage,
              let query = activeSearchQuery else { return }
        loadingNextPage = true
        nextSearchPage = nil
        retryNextPage = false
        showState(nil)
        pageSpinner.startAnimating()
        let current = generation
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await service.search(query, page: page)
                guard current == generation else { return }
                guard ownsCurrentProfile else { invalidateAuthority(); return }
                let seen = Set(results.map(\.id))
                results += response.results.filter { !seen.contains($0.id) }
                nextSearchPage = response.page < response.totalPages ? response.page + 1 : nil
                table.reloadData()
                updateSection()
                showState(nil)
            } catch {
                guard current == generation else { return }
                if !ownsCurrentProfile { invalidateAuthority(); return }
                nextSearchPage = page
                retryNextPage = true
                showState("Couldn’t load more results. " + failureMessage(error),
                          symbol: "exclamationmark.triangle", canRetry: true)
            }
            loadingNextPage = false
            pageSpinner.stopAnimating()
        }
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: SiloRequestCell.reuseIdentifier,
                                                       for: indexPath) as? SiloRequestCell else { fatalError("SiloRequestCell registration failed") }
        if modeSearch {
            let item = results[indexPath.row]
            cell.configure(type: item.mediaType, kind: mediaKind(item.mediaType, year: item.year), title: item.title,
                           status: searchStatus(item), action: searchAction(item))
        } else {
            let item = records[indexPath.row]
            cell.configure(type: item.mediaType, kind: mediaKind(item.mediaType, year: item.year), title: item.title,
                           status: recordStatus(item), action: item.canCancel ? "Select for options" : "View status")
        }
        return cell
    }

    private func mediaKind(_ type: SiloRequestMediaType, year: Int?) -> String {
        let kind = type == .series ? "Series" : type == .movie ? "Movie" : "Media"
        return year.map { "\(kind) · \($0)" } ?? kind
    }

    private func searchStatus(_ item: SiloRequestSearchResult) -> String {
        let request = item.request
        var parts: [String] = []
        if let state = request.state ?? request.status, !state.isEmpty {
            parts.append(state.replacingOccurrences(of: "_", with: " ").capitalized)
        } else if request.requestedByViewer == true || request.requestId != nil {
            parts.append("Requested")
        } else if item.availability == .available {
            parts.append("In library")
        } else if item.mediaType != .all && request.requestable && item.availability == .missing {
            parts.append("Available to request")
        } else if item.availability == .unknown {
            parts.append("Availability unknown")
        } else {
            parts.append(item.mediaType == .all ? "Unsupported media type" : request.reason ?? "Unavailable to request")
        }
        if request.following == true { parts.append("Following") }
        return parts.joined(separator: " · ")
    }

    private func searchAction(_ item: SiloRequestSearchResult) -> String {
        if item.mediaType != .all && item.request.requestable && item.availability == .missing { return "Request title" }
        if item.mediaType != .all && capability?.canFollow == true && item.request.canFollow { return "Follow request" }
        if item.mediaType != .all && capability?.canFollow == true && item.request.canUnfollow { return "Unfollow request" }
        return "View details"
    }

    private func recordStatus(_ item: SiloRequestRecord) -> String {
        switch item.outcome {
        case .declined: return "Declined"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        case .active, .unknown: return item.progress
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard ownsCurrentProfile, capability?.isAvailable == true else { invalidateAuthority(); return }
        guard mutationTask == nil, presentedViewController == nil else { return }
        guard indexPath.row >= 0, indexPath.row < (modeSearch ? results.count : records.count) else { return }
        let actions = UIAlertController(title: modeSearch ? results[indexPath.row].title : records[indexPath.row].title,
                                        message: nil, preferredStyle: .alert)
        if modeSearch {
            let item = results[indexPath.row]
            var details = [searchStatus(item)]
            if let reason = item.request.reason, !reason.isEmpty { details.append(reason) }
            if capability?.canFollow != true && (item.request.canFollow || item.request.canUnfollow) {
                details.append("Following is not available for this profile.")
            }
            if let overview = item.overview, !overview.isEmpty { details.append(overview) }
            actions.message = details.joined(separator: "\n\n")
            if item.mediaType != .all && item.request.requestable && item.availability == .missing {
                actions.addAction(UIAlertAction(title: "Request", style: .default) { [weak self] _ in
                    self?.mutate { service in _ = try await service.create(item) }
                })
            }
            if item.mediaType != .all && capability?.canFollow == true && item.request.canFollow {
                actions.addAction(UIAlertAction(title: "Follow", style: .default) { [weak self] _ in
                    self?.mutate { service in _ = try await service.follow(item) }
                })
            }
            if item.mediaType != .all && capability?.canFollow == true && item.request.canUnfollow {
                actions.addAction(UIAlertAction(title: "Unfollow", style: .default) { [weak self] _ in
                    self?.mutate { service in try await service.unfollow(item) }
                })
            }
        } else {
            let item = records[indexPath.row]
            var details = [recordStatus(item)]
            if item.canCancel {
                details.append("This request can still be cancelled before submission.")
            } else if item.outcome == .active {
                details.append("Cancellation is not available for this request.")
            }
            if let error = item.lastError, !error.isEmpty { details.append(error) }
            actions.message = details.joined(separator: "\n\n")
            if item.canCancel {
                actions.addAction(UIAlertAction(title: "Cancel request", style: .destructive) { [weak self] _ in
                    self?.mutate { service in _ = try await service.cancel(item) }
                })
            }
        }
        actions.addAction(UIAlertAction(title: "Close", style: .cancel))
        present(actions, animated: true)
    }

    func mutate(_ action: @escaping (SiloRequests) async throws -> Void) {
        guard ownsCurrentProfile, capability?.isAvailable == true, mutationTask == nil else { return }
        generation += 1
        loadTask?.cancel()
        loadingNextPage = false
        pageSpinner.stopAnimating()
        searchBar.isUserInteractionEnabled = false
        showState("Updating request…", loading: true)
        mutationTask = Task { [weak self] in
            guard let self else { return }
            do { try await action(service) }
            catch {
                guard ownsCurrentProfile else { invalidateAuthority(); return }
                let unavailable = (error as? SiloRequestsError).map {
                    switch $0 {
                    case .notPermitted, .unavailable: true
                    default: false
                    }
                } ?? false
                let explanation = unavailable
                    ? failureMessage(error)
                    : failureMessage(error) + "\n\nThe change will not be sent again automatically. Check the refreshed status before trying again."
                let alert = UIAlertController(title: unavailable ? "Action unavailable" : "Request status uncertain",
                                              message: explanation, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                presentMutationError(alert)
            }
            mutationTask = nil
            guard ownsCurrentProfile else { invalidateAuthority(); return }
            // Always reconcile from the server, including uncertain mutation outcomes.
            refresh()
        }
    }

    private func presentMutationError(_ alert: UIAlertController) {
        // A fast server failure can arrive while UIKit is still dismissing the
        // action alert. Presenting immediately in that interval drops the error.
        let presentWhenReady = { [weak self] in
            guard let self, ownsCurrentProfile, viewIfLoaded?.window != nil else { return }
            if let previous = presentedViewController {
                previous.dismiss(animated: false) { [weak self] in
                    guard let self, ownsCurrentProfile, viewIfLoaded?.window != nil else { return }
                    present(alert, animated: true)
                }
            } else {
                present(alert, animated: true)
            }
        }
        if let transition = presentedViewController?.transitionCoordinator ?? transitionCoordinator,
           transition.animate(alongsideTransition: nil, completion: { _ in
               DispatchQueue.main.async { presentWhenReady() }
           }) {
            return
        }
        presentWhenReady()
    }
}
