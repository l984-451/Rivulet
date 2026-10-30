// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

/// The server supplies every facet and opaque choice ID shown here.
@MainActor final class SiloCatalogFilterViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let facets: [MediaCatalogFacet]
    private var selection: MediaCatalogFilter
    private let apply: (MediaCatalogFilter) -> Void
    private let table = UITableView(frame: .zero, style: .plain)

    init(facets: [MediaCatalogFacet], selection: MediaCatalogFilter,
         apply: @escaping (MediaCatalogFilter) -> Void) {
        self.facets = facets
        self.selection = selection
        self.apply = apply
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let title = UILabel()
        title.text = "Filters"
        title.font = .systemFont(ofSize: 46, weight: .bold)
        title.textColor = .white
        let reset = UIButton(type: .system)
        reset.setTitle("Reset", for: .normal)
        reset.addAction(UIAction { [weak self] _ in
            self?.selection = MediaCatalogFilter(selectedChoices: [:])
            self?.table.reloadData()
        }, for: .primaryActionTriggered)
        let done = UIButton(type: .system)
        done.setTitle("Apply", for: .normal)
        done.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.apply(self.selection)
            self.dismiss(animated: true)
        }, for: .primaryActionTriggered)
        let header = UIStackView(arrangedSubviews: [title, reset, done])
        header.axis = .horizontal
        header.spacing = 36
        header.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(table)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 32),
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 64),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -64),
            table.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
            table.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 64),
            table.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -64),
            table.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }

    func numberOfSections(in tableView: UITableView) -> Int { facets.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        facets[section].choices.count
    }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        facets[section].title
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "choice")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "choice")
        let facet = facets[indexPath.section]
        let choice = facet.choices[indexPath.row]
        cell.textLabel?.text = choice.title
        cell.detailTextLabel?.text = choice.count.map(String.init)
        cell.accessoryType = selection.selectedChoices[facet.id]?.contains(choice.id) == true ? .checkmark : .none
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let facet = facets[indexPath.section]
        let id = facet.choices[indexPath.row].id
        var values = selection.selectedChoices[facet.id] ?? []
        if let index = values.firstIndex(of: id) { values.remove(at: index) }
        else { values.append(id) }
        if values.isEmpty { selection.selectedChoices.removeValue(forKey: facet.id) }
        else { selection.selectedChoices[facet.id] = values }
        tableView.reloadRows(at: [indexPath], with: .none)
    }
}
