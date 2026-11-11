import SwiftUI
import AppKit
import FinderCore

// MARK: - 搜索栏

struct SearchBar: View {
    @ObservedObject var tab: TabModel
    @EnvironmentObject var app: AppModel

    enum DatePreset: String, CaseIterable, Identifiable {
        case any, today, week, month, year, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .any: return "不限日期"
            case .today: return "今天"
            case .week: return "最近 7 天"
            case .month: return "最近 30 天"
            case .year: return "最近一年"
            case .custom: return "自定义…"
            }
        }
    }

    @State private var text = ""
    @State private var exts = ""
    @State private var scopeIndex = 0
    @State private var minText = ""
    @State private var maxText = ""
    @State private var minUnit = 1
    @State private var maxUnit = 1
    @State private var datePreset: DatePreset = .any
    @State private var fromDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var toDate = Date()

    let unitNames = ["字节", "KB", "MB", "GB"]
    let unitMultipliers: [Double] = [1, 1_000, 1_000_000, 1_000_000_000]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("名称包含（多个词用空格分隔）", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                TextField("扩展名，如 jpg,png", text: $exts)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .onSubmit { runSearch() }
                Picker("", selection: $scopeIndex) {
                    Text("文件和文件夹").tag(0)
                    Text("仅文件").tag(1)
                    Text("仅文件夹").tag(2)
                }
                .labelsHidden()
                .frame(width: 130)
            }
            HStack(spacing: 8) {
                Group {
                Text("大小 ≥")
                TextField("", text: $minText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Picker("", selection: $minUnit) {
                    ForEach(0..<unitNames.count, id: \.self) { i in Text(unitNames[i]).tag(i) }
                }
                .labelsHidden()
                .frame(width: 70)
                Text("≤")
                TextField("", text: $maxText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Picker("", selection: $maxUnit) {
                    ForEach(0..<unitNames.count, id: \.self) { i in Text(unitNames[i]).tag(i) }
                }
                .labelsHidden()
                .frame(width: 70)
                }

                Group {
                Divider().frame(height: 18)

                Picker("", selection: $datePreset) {
                    ForEach(DatePreset.allCases) { p in Text(p.title).tag(p) }
                }
                .labelsHidden()
                .frame(width: 120)
                if datePreset == .custom {
                    DatePicker("", selection: $fromDate, displayedComponents: .date).labelsHidden()
                    Text("至")
                    DatePicker("", selection: $toDate, displayedComponents: .date).labelsHidden()
                }

                }

                Spacer()
                if tab.isSearching {
                    ProgressView().controlSize(.small)
                }
                Button("搜索") { runSearch() }
                    .keyboardShortcut(.defaultAction)
                Button("清除") { clear() }
            }
            Text("在当前文件夹“\(tab.title)”及其所有子文件夹中搜索。设置大小条件时只匹配文件。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    func buildCriteria() -> SearchCriteria {
        var c = SearchCriteria()
        c.text = text
        let separators = CharacterSet(charactersIn: ",，;； ")
        c.extensions = exts
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }
            .filter { !$0.isEmpty }
        if let v = Double(minText.replacingOccurrences(of: ",", with: ".")) {
            c.minSize = Int64(v * unitMultipliers[minUnit])
        }
        if let v = Double(maxText.replacingOccurrences(of: ",", with: ".")) {
            c.maxSize = Int64(v * unitMultipliers[maxUnit])
        }
        let now = Date()
        switch datePreset {
        case .any: break
        case .today: c.modifiedAfter = Calendar.current.startOfDay(for: now)
        case .week: c.modifiedAfter = now.addingTimeInterval(-7 * 86400)
        case .month: c.modifiedAfter = now.addingTimeInterval(-30 * 86400)
        case .year: c.modifiedAfter = now.addingTimeInterval(-365 * 86400)
        case .custom:
            c.modifiedAfter = Calendar.current.startOfDay(for: min(fromDate, toDate))
            let end = Calendar.current.startOfDay(for: max(fromDate, toDate))
            c.modifiedBefore = end.addingTimeInterval(86400 - 1)
        }
        switch scopeIndex {
        case 1: c.scope = .filesOnly
        case 2: c.scope = .foldersOnly
        default: c.scope = .any
        }
        c.includeHidden = app.showHidden
        return c
    }

    func runSearch() {
        let c = buildCriteria()
        if c.isEmpty {
            NSSound.beep()
            return
        }
        tab.startSearch(c)
    }

    func clear() {
        text = ""
        exts = ""
        minText = ""
        maxText = ""
        datePreset = .any
        scopeIndex = 0
        if tab.searchCriteria != nil { tab.clearSearch() }
    }
}

// MARK: - 批量重命名

enum RuleType: String, CaseIterable, Identifiable {
    case replace, prefix, suffix, numbering, changeCase

    var id: String { rawValue }

    var title: String {
        switch self {
        case .replace: return "查找替换"
        case .prefix: return "添加前缀"
        case .suffix: return "添加后缀"
        case .numbering: return "添加编号"
        case .changeCase: return "大小写"
        }
    }
}

struct RuleDraft: Identifiable {
    let id = UUID()
    var type: RuleType = .replace
    var text1 = ""
    var text2 = ""
    var regex = false
    var caseSensitive = false
    var start = 1
    var step = 1
    var digits = 2
    var atStart = false
    var separator = "_"
    var caseMode: CaseMode = .lower

    func rule() -> RenameRule {
        switch type {
        case .replace:
            return RenameRule(.replace(find: text1, with: text2, regex: regex, caseSensitive: caseSensitive))
        case .prefix:
            return RenameRule(.prefix(text1))
        case .suffix:
            return RenameRule(.suffix(text1))
        case .numbering:
            return RenameRule(.numbering(start: start, step: step, digits: digits, atStart: atStart, separator: separator))
        case .changeCase:
            return RenameRule(.changeCase(caseMode))
        }
    }
}

struct BatchRenameSheet: View {
    let items: [FileItem]
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [RuleDraft] = [RuleDraft()]

    var plans: [RenamePlan] {
        return BatchRenamer.plan(urls: items.map { $0.url }, rules: drafts.map { $0.rule() })
    }

    var body: some View {
        let current = plans
        let changedCount = current.filter { $0.changed && $0.problem == nil }.count
        let hasProblem = current.contains { $0.problem != nil }
        VStack(alignment: .leading, spacing: 12) {
            Text("批量重命名 \(items.count) 个项目")
                .font(.title3.bold())
            Text("规则按顺序依次生效，只修改主文件名，扩展名保持不变。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($drafts) { $d in
                        RuleRow(draft: $d) {
                            drafts.removeAll { $0.id == d.id }
                        }
                    }
                }
            }
            .frame(maxHeight: 190)

            Button {
                drafts.append(RuleDraft())
            } label: {
                Label("添加规则", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)

            Divider()
            Text("预览")
                .font(.headline)
            List(current) { p in
                HStack(spacing: 8) {
                    Text(p.oldName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    Text(p.newName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(p.problem != nil ? Color.red : (p.changed ? Color.primary : Color.secondary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let problem = p.problem {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(minHeight: 160)

            HStack {
                Text(hasProblem ? "有冲突的项目，请调整规则后再执行" : "将重命名 \(changedCount) 个项目")
                    .foregroundStyle(hasProblem ? Color.red : Color.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("重命名") {
                    app.runBatchRename(current)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(hasProblem || changedCount == 0)
            }
        }
        .padding(18)
        .frame(width: 640, height: 560)
    }
}

struct RuleRow: View {
    @Binding var draft: RuleDraft
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Picker("", selection: $draft.type) {
                ForEach(RuleType.allCases) { t in Text(t.title).tag(t) }
            }
            .labelsHidden()
            .frame(width: 100)

            switch draft.type {
            case .replace:
                TextField("查找", text: $draft.text1).textFieldStyle(.roundedBorder)
                Text("→")
                TextField("替换为", text: $draft.text2).textFieldStyle(.roundedBorder)
                Toggle("正则", isOn: $draft.regex).toggleStyle(.checkbox)
                Toggle("区分大小写", isOn: $draft.caseSensitive).toggleStyle(.checkbox)
            case .prefix, .suffix:
                TextField(draft.type == .prefix ? "前缀文字" : "后缀文字", text: $draft.text1)
                    .textFieldStyle(.roundedBorder)
            case .numbering:
                Stepper("起始 \(draft.start)", value: $draft.start, in: 0...999999)
                Stepper("位数 \(draft.digits)", value: $draft.digits, in: 1...8)
                Picker("", selection: $draft.atStart) {
                    Text("放在名称后").tag(false)
                    Text("放在名称前").tag(true)
                }
                .labelsHidden()
                .frame(width: 100)
                TextField("分隔", text: $draft.separator)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
            case .changeCase:
                Picker("", selection: $draft.caseMode) {
                    ForEach(CaseMode.allCases, id: \.self) { m in Text(m.title).tag(m) }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }
}
