import MonoDeckCore
import SwiftUI

struct ResultView: View {
  var text: InterfaceText
  var result: OperationResult
  var retry: (() -> Void)? = nil
  var retryTitle: String? = nil
  var context: String? = nil
  var dismissTitle: String? = nil
  var dismiss: () -> Void
  @State private var showingUpdateError = false
  private var isWorktreeUpdate: Bool { result.command == "worktree.update" }
  private var isUpdate: Bool { isWorktreeUpdate || result.command == "repo.update" }

  var body: some View {
    let items = text.resultDisplayItems(result)
    return VStack(alignment: .leading, spacing: isUpdate ? 12 : 16) {
      VStack(alignment: .leading, spacing: isUpdate ? 4 : 6) {
        resultHeader
        if let context {
          Text(context).font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary)
        }
        if !isUpdate, let summary = text.resultSummaryText(result) {
          Text(summary).font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary)
            .monospacedDigit()
        }
      }
      VStack(spacing: isUpdate ? 0 : 16) {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            if result.command == "workspace.open", let workspace = result.workspace {
              Text(workspace).font(DialogTypography.path)
            }
            if result.command == "group.edit", result.status == .confirmationRequired {
              Text(text.string(.uiGroupMembershipChangedReviewAgain))
            }
            if let raw = result.message {
              if isWorktreeUpdate {
                Button(text.string(.uiViewDetails)) { showingUpdateError.toggle() }
                  .detailsPopover(isPresented: $showingUpdateError) {
                    IssueDescriptionView(
                      message: text.message(result), details: Git.sanitize(raw), text: text
                    )
                    .padding(16).frame(width: 420)
                  }
              } else {
                IssueDescriptionView(
                  message: text.message(result), details: Git.sanitize(raw), text: text)
              }
            }
            if isUpdate, !items.isEmpty {
              UpdateResultsView(
                text: text, items: items, workspace: result.workspace,
                isWorktreeUpdate: isWorktreeUpdate)
            } else {
              ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                itemContents(item, count: items.count)
              }
            }
          }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }.frame(maxHeight: 360)
        Divider()
      }
      HStack {
        if let retry {
          Button(retryTitle ?? text.string(.uiChooseAnother), action: retry)
          Spacer()
          Button(dismissTitle ?? text.string(.uiCancel), role: .cancel, action: dismiss)
            .keyboardShortcut(.cancelAction)
        } else {
          Button(dismissTitle ?? text.string(.uiOk), action: dismiss).keyboardShortcut(
            .defaultAction)
        }
      }.frame(maxWidth: .infinity, alignment: .trailing)
    }.font(DialogTypography.body).padding(24).frame(width: DesignStyle.sheetWidth).background(
      DesignStyle.background)
  }

  private var resultHeader: some View {
    HStack(spacing: 8) {
      resultIcon
      Text(text.resultTitle(result)).font(DialogTypography.title)
    }
  }

  private var resultIcon: DialogStatusIcon {
    switch result.status {
    case .success where result.hasWarnings, .partialSuccess, .confirmationRequired: .caution
    case .success: DialogStatusIcon(symbol: "checkmark.circle", color: .green)
    case .failed: .failure
    case .skipped: DialogStatusIcon(symbol: "info.circle", color: .secondary)
    case .cancelled: DialogStatusIcon(symbol: "stop.circle", color: .secondary)
    }
  }

  private func itemContents(_ item: ItemResult, count: Int) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      if result.command != "workspace.open" {
        Text(item.resource.path).font(DialogTypography.path)
        if result.command != "repo.add" || count > 1 || result.status != .failed {
          Text(text.resultStatus(item)).font(DialogTypography.auxiliary).foregroundStyle(
            DesignStyle.secondary)
        }
      }
      let message = text.resultMessage(item, overallMessage: result.message)
      if let message { Text(message).foregroundStyle(DesignStyle.secondary) }
      ForEach(text.effectSummaries(item, workspace: result.workspace), id: \.self) {
        Text($0).font(DialogTypography.auxiliary)
      }
      if let trash = item.trashPath {
        Text(text.string(.uiTrash2(trash))).font(DialogTypography.path)
      }
      let errorDetails = item.message.flatMap { raw in
        message != nil && message != raw ? Git.sanitize(raw) : nil
      }
      if !item.effects.isEmpty || errorDetails != nil {
        DisclosureGroup(text.string(.uiDetails)) {
          VStack(alignment: .leading, spacing: 4) {
            if let errorDetails { Text(errorDetails) }
            ForEach(Array(item.effects.enumerated()), id: \.offset) { _, effect in
              Text(
                text.string(
                  .uiOperationEffectDetails(
                    text.statusText(effect.action), effect.target, text.statusText(effect.state))))
            }
          }.font(DialogTypography.path).frame(maxWidth: .infinity, alignment: .leading)
        }.font(DialogTypography.auxiliary).foregroundStyle(DesignStyle.secondary)
      }
    }
  }
}
