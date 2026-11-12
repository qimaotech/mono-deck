import MonoDeckCore
import SwiftUI

struct UpdateResultsView: View {
  let text: InterfaceText
  let items: [ItemResult]
  let workspace: String?
  let isWorktreeUpdate: Bool
  var body: some View {
    DialogResourceTable(
      rows: displayRows(),
      targetHeading: text.string(isWorktreeUpdate ? .uiWorktreeUpdateTarget : .uiRepository),
      statusHeading: text.string(.uiResult),
      statusWidth: isWorktreeUpdate ? 112 : 96
    ) { row in
      let resource = row.resource
      let title =
        resource.repositoryID ?? resource.groupName ?? (resource.path as NSString).lastPathComponent
      DialogResourceLabel(resource: resource, title: title, isHeader: resource.kind == .group)
        .help(fullPath(for: resource))
    } status: { row in
      if let item = row.item {
        UpdateResultButton(
          text: text, item: item, fullPath: fullPath(for: row.resource),
          isWorktreeUpdate: isWorktreeUpdate)
      }
    }
  }

  private func fullPath(for resource: Resource) -> String {
    workspace.map { URL(fileURLWithPath: $0).appending(path: resource.path).path } ?? resource.path
  }

  private func displayRows() -> [Row] {
    var shownGroups = Set(
      items.compactMap { item -> String? in
        if case .group(let name) = item.resource { return name }
        return nil
      })
    var rows: [Row] = []
    for item in items {
      if isWorktreeUpdate, case .member(let groupName, _) = item.resource,
        shownGroups.insert(groupName).inserted
      {
        rows.append(Row(resource: .group(groupName), item: nil))
      }
      rows.append(Row(resource: item.resource, item: item))
    }
    return rows
  }

  private struct Row: Identifiable {
    let resource: Resource
    let item: ItemResult?
    var id: String { resource.id }
  }
}

private struct UpdateResultButton: View {
  var text: InterfaceText
  var item: ItemResult
  var fullPath: String
  var isWorktreeUpdate: Bool
  @State private var showingDetails = false

  var body: some View {
    let status = UpdateResultStatus(item)
    return Button {
      showingDetails.toggle()
    } label: {
      InlineStatusLabel(title: statusLabel, symbol: status.symbolName, iconColor: status.iconColor)
        .padding(.horizontal, 6).frame(minHeight: 26)
        .contentShape(Rectangle())
    }
    .buttonStyle(
      HoverPlainButtonStyle(shape: RoundedRectangle(cornerRadius: 6), hoverForeground: .primary)
    )
    .background(showingDetails ? DesignStyle.field : .clear, in: RoundedRectangle(cornerRadius: 6))
    .textSelection(.disabled)
    .help(text.string(.uiViewDetails))
    .accessibilityIdentifier("\(updateID)-status-\(item.resource.id)")
    .accessibilityValue(text.string(showingDetails ? .uiExpanded : .uiCollapsed))
    .accessibilityHint(text.string(.uiViewDetails))
    .detailsPopover(isPresented: $showingDetails) {
      UpdateResultPopover(
        text: text, item: item, fullPath: fullPath,
        updateID: updateID, branchDetails: isWorktreeUpdate ? branchDetails : nil)
    }
    .fixedSize(horizontal: !isWorktreeUpdate, vertical: true)
  }

  private var branchDetails: String {
    let branch = item.data?["branch"] ?? "—"
    let base = item.data?["base"] ?? "—"
    return "\(text.string(.uiHeadBranch)) \(branch)\n\(text.string(.uiBaseBranch)) \(base)"
  }
  private var updateID: String { isWorktreeUpdate ? "worktree-update" : "repo-update" }
  private var statusLabel: String {
    guard isWorktreeUpdate else { return text.resultStatus(item) }
    switch item.status {
    case .success: return text.string(.uiWorktreeUpdateSucceeded)
    case .failed: return text.string(.uiFailed2)
    default: return text.resultStatus(item)
    }
  }
}

struct UpdateResultPopover: View {
  var text: InterfaceText
  var item: ItemResult
  var fullPath: String
  var updateID: String
  var branchDetails: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      details
    }
    .font(DialogTypography.auxiliary).padding(16).frame(width: 420)
    .textSelection(.enabled)
    .accessibilityIdentifier("\(updateID)-details-\(item.resource.id)")
  }

  private var details: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if let message { Text(message).font(DialogTypography.body) }
        Text(fullPath).font(DialogTypography.path).foregroundStyle(DesignStyle.secondary)
        if let branchDetails { Text(branchDetails).font(DialogTypography.path) }
        if !item.effects.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(item.effects.enumerated()), id: \.offset) { _, effect in
              VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                  Text(text.statusText(effect.action))
                  Spacer()
                  Text(text.statusText(effect.state)).foregroundStyle(DesignStyle.secondary)
                }
                if effect.target != item.resource.path, effect.target != fullPath {
                  Text(effect.target).font(DialogTypography.path).foregroundStyle(
                    DesignStyle.secondary)
                }
              }
            }
          }
        }
        if let head = item.data?["actual-head"] {
          Text(verbatim: "HEAD: \(head)").font(DialogTypography.path)
        }
        if let workingTree = item.data?["working-tree"] {
          Text(
            text.string(
              .uiWorkingTree2(text.statusText(workingTree == "clean" ? "Clean" : "Dirty"))))
        }
        if let diagnostic {
          Divider()
          Text(diagnostic).font(DialogTypography.path).foregroundStyle(DesignStyle.secondary)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    }.frame(maxHeight: 300)
  }

  private var message: String? {
    text.resultMessage(item, overallMessage: nil).map { Git.sanitize($0) }
  }
  private var diagnostic: String? {
    guard let raw = item.message else { return nil }
    let sanitized = Git.sanitize(raw)
    return sanitized.isEmpty || sanitized == message ? nil : sanitized
  }
}

enum UpdateResultStatus: Equatable {
  case updated, skipped, failed, cancelled

  init(_ item: ItemResult) {
    self =
      switch item.status {
      case .failed: .failed
      case .skipped: .skipped
      case .cancelled: .cancelled
      default: .updated
      }
  }

  var symbolName: String {
    switch self {
    case .updated: "checkmark.circle"
    case .skipped: "info.circle"
    case .failed: "exclamationmark.circle"
    case .cancelled: "stop.circle"
    }
  }

  var iconColor: Color {
    switch self {
    case .updated: .green
    case .failed: .red
    case .skipped, .cancelled: .secondary
    }
  }
}
