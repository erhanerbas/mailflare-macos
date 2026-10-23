import SwiftUI

/// The popup that creates or edits a custom tab: a name, an icon, and the rules that pick its mail.
struct CustomTabEditor: View {
	@Environment(MailStore.self) private var store
	@Environment(\.dismiss) private var dismiss

	@State private var tab: CustomTab
	@FocusState private var nameFocused: Bool
	private let isNew: Bool
	/// The footer's height, which a dropdown must not open under.
	private static let footerRoom: CGFloat = 70

	init(tab: CustomTab, isNew: Bool) {
		_tab = State(initialValue: tab)
		self.isNew = isNew
	}

	var body: some View {
		ModalScaffold(title: isNew ? "New Custom Tab" : "Edit Custom Tab", width: 520) {
			VStack(alignment: .leading, spacing: 16) {
				VStack(alignment: .leading, spacing: 6) {
					label("Name")
					TextField("Invoices, Newsletters, Boss…", text: $tab.name)
						.textFieldStyle(.card)
						.focused($nameFocused)
						.onSubmit { if tab.isValid { save() } }
				}
				VStack(alignment: .leading, spacing: 6) {
					label("Icon")
					iconGrid
				}
				VStack(alignment: .leading, spacing: 8) {
					label("Show mail that matches")
					rulesList
					HStack(spacing: 8) {
						Button("Add Rule") { tab.rules.append(CustomTab.Rule(kind: nextKind(tab.rules))) }
						Button("Add Group") { tab.groups.append(CustomTab.Group(matchAll: !tab.matchAll, rules: [CustomTab.Rule(kind: nextKind([]))])) }
					}
					.buttonStyle(.pill)
					preview
				}
				.raisedWhileDropdownOpen()
			}
		} footer: {
			HStack(spacing: 8) {
				if !isNew {
					Button("Delete") { store.deleteCustomTab(tab.id); dismiss() }
						.buttonStyle(.pill).foregroundStyle(.red)
				}
				Spacer()
				Button("Cancel") { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
				Button(isNew ? "Create" : "Save") { save() }
					.buttonStyle(.pillProminent).disabled(!tab.isValid).keyboardShortcut(.defaultAction)
			}
		}
		.onAppear { nameFocused = true }
	}

	private func save() {
		store.saveCustomTab(tab)
		dismiss()
	}

	private func label(_ text: String) -> some View {
		Text(text).font(Typography.meta.weight(.medium)).foregroundStyle(.secondary)
	}

	/// A kind not used yet, so the first few rules added are different ones, not the same one again.
	private func nextKind(_ rules: [CustomTab.Rule]) -> CustomTab.Rule.Kind {
		let used = Set(rules.map(\.kind))
		return CustomTab.Rule.Kind.allCases.first { !used.contains($0) } ?? .from
	}

	// MARK: Icon

	private var iconGrid: some View {
		LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 10), alignment: .leading, spacing: 6) {
			ForEach(CustomTab.iconChoices, id: \.rawValue) { icon in
				let chosen = tab.icon == icon.rawValue
				Button { tab.icon = icon.rawValue } label: {
					HIcon(icon, size: 16)
						.foregroundStyle(chosen ? Color.primary : Color.secondary)
						.frame(width: 34, height: 34)
						.background(chosen ? AppTheme.railSelection : AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
						.overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
							.stroke(chosen ? Color.accentColor.opacity(0.6) : AppTheme.composerStroke, lineWidth: 1))
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
			}
		}
	}

	// MARK: Rules

	/// The rules one per line, then the groups, joined by "and" or "or" between neighbours.
	private var rulesList: some View {
		VStack(alignment: .leading, spacing: 6) {
			ForEach($tab.rules) { $rule in
				if rule.id != tab.rules.first?.id { connector($tab.matchAll) }
				ruleLine($rule) { tab.rules.removeAll { $0.id == rule.id } }
			}
			ForEach($tab.groups) { $group in
				if !(tab.rules.isEmpty && group.id == tab.groups.first?.id) { connector($tab.matchAll) }
				groupBlock($group)
			}
		}
	}

	/// A group: its own lines inside a rail, joined by its own "and" or "or".
	private func groupBlock(_ group: Binding<CustomTab.Group>) -> some View {
		HStack(alignment: .top, spacing: 10) {
			RoundedRectangle(cornerRadius: 1, style: .continuous).fill(AppTheme.composerStroke).frame(width: 2)
			VStack(alignment: .leading, spacing: 6) {
				ForEach(group.rules) { $rule in
					if rule.id != group.wrappedValue.rules.first?.id { connector(group.matchAll) }
					ruleLine($rule) { group.wrappedValue.rules.removeAll { $0.id == rule.id } }
				}
				HStack(spacing: 8) {
					Button("Add Rule") { group.wrappedValue.rules.append(CustomTab.Rule(kind: nextKind(group.wrappedValue.rules))) }
					Button("Remove Group") { tab.groups.removeAll { $0.id == group.wrappedValue.id } }.foregroundStyle(.red)
				}
				.buttonStyle(.pill)
			}
		}
		.raisedWhileDropdownOpen()
	}

	/// "and" / "or" between two lines. Every connector of a list is the same choice.
	private func connector(_ matchAll: Binding<Bool>) -> some View {
		HStack {
			DropdownPicker(options: [("and", true), ("or", false)], selection: matchAll, width: 100, style: .compact, reservedBelow: Self.footerRoom)
			Spacer(minLength: 0)
		}
		.raisedWhileDropdownOpen()
	}

	/// One rule on one line: a field cut into the kind, the value and a remove button by dividers.
	private func ruleLine(_ rule: Binding<CustomTab.Rule>, remove: @escaping () -> Void) -> some View {
		let kind = rule.wrappedValue.kind
		return HStack(spacing: 0) {
			DropdownPicker(options: CustomTab.Rule.Kind.allCases.map { ($0.title, $0) }, selection: rule.kind, style: .bare, reservedBelow: Self.footerRoom)
				.frame(width: 190)
			divider
			Group {
				if let placeholder = kind.placeholder {
					TextField(placeholder, text: rule.text)
						.textFieldStyle(.plain).font(Typography.body)
						.padding(.horizontal, 12).padding(.vertical, 10)
				} else if kind == .received {
					DropdownPicker(options: CustomTab.Rule.dayChoices.map { ($0.label, $0.days) }, selection: rule.days, style: .bare, reservedBelow: Self.footerRoom)
				} else {
					Text(kind.hint ?? "").font(Typography.body).foregroundStyle(.tertiary)
						.padding(.horizontal, 12).padding(.vertical, 10)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			divider
			Button(action: remove) {
				HIcon(.close, size: 12).foregroundStyle(.secondary).frame(width: 36, height: 38).contentShape(Rectangle())
			}
			.buttonStyle(.plain).help("Remove rule")
		}
		.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.composerStroke, lineWidth: 1))
		.raisedWhileDropdownOpen()
	}

	private var divider: some View {
		Rectangle().fill(AppTheme.composerStroke).frame(width: 1, height: 22)
	}

	/// What the rules pick out of the Inbox shown right now, so a rule can be checked as it is typed.
	@ViewBuilder
	private var preview: some View {
		if tab.activeRules.isEmpty && tab.activeGroups.isEmpty {
			Text("Add a rule to choose which mail this tab shows. Separate several values with commas: any of them matches.")
				.font(Typography.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
		} else {
			let found = store.preview(of: tab)
			Text("Right now: \(found.total) message\(found.total == 1 ? "" : "s") in the Inbox, \(found.unread) unread.")
				.font(Typography.meta).foregroundStyle(.secondary)
		}
	}
}
