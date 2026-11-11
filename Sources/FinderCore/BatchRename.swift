import Foundation

public enum CaseMode: String, CaseIterable {
    case lower
    case upper
    case capitalized

    public var title: String {
        switch self {
        case .lower: return "全部小写"
        case .upper: return "全部大写"
        case .capitalized: return "每个单词首字母大写"
        }
    }
}

public struct RenameRule: Identifiable, Equatable {
    public enum Kind: Equatable {
        case prefix(String)
        case suffix(String)
        case replace(find: String, with: String, regex: Bool, caseSensitive: Bool)
        case numbering(start: Int, step: Int, digits: Int, atStart: Bool, separator: String)
        case changeCase(CaseMode)
    }

    public let id = UUID()
    public var kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }
}

public struct RenamePlan: Identifiable {
    public let url: URL
    public let oldName: String
    public var newName: String
    public var problem: String?

    public var id: URL { url }
    public var changed: Bool { return oldName != newName }

    public init(url: URL, oldName: String, newName: String, problem: String? = nil) {
        self.url = url
        self.oldName = oldName
        self.newName = newName
        self.problem = problem
    }
}

public enum BatchRenamer {
    /// 对单个名称依次应用所有规则。规则只作用于“主文件名”，扩展名保持不变。
    public static func transform(_ name: String, index: Int, rules: [RenameRule]) -> (name: String, error: String?) {
        let ns = name as NSString
        let ext = ns.pathExtension
        var base = ns.deletingPathExtension

        for rule in rules {
            switch rule.kind {
            case .prefix(let p):
                base = p + base
            case .suffix(let s):
                base = base + s
            case .replace(let find, let with, let regex, let caseSensitive):
                if find.isEmpty { continue }
                if regex {
                    do {
                        let re = try NSRegularExpression(pattern: find, options: caseSensitive ? [] : [.caseInsensitive])
                        let range = NSRange(location: 0, length: (base as NSString).length)
                        base = re.stringByReplacingMatches(in: base, options: [], range: range, withTemplate: with)
                    } catch {
                        return (name, "正则表达式无效")
                    }
                } else {
                    base = base.replacingOccurrences(of: find, with: with, options: caseSensitive ? [] : [.caseInsensitive])
                }
            case .numbering(let start, let step, let digits, let atStart, let separator):
                let n = String(start + step * index)
                let pad = String(repeating: "0", count: max(0, digits - n.count))
                let num = pad + n
                base = atStart ? (num + separator + base) : (base + separator + num)
            case .changeCase(let mode):
                switch mode {
                case .lower: base = base.lowercased()
                case .upper: base = base.uppercased()
                case .capitalized: base = base.capitalized
                }
            }
        }
        let full = ext.isEmpty ? base : base + "." + ext
        return (full, nil)
    }

    /// 生成预览计划，并标出会冲突的项目
    public static func plan(urls: [URL], rules: [RenameRule]) -> [RenamePlan] {
        let fm = FileManager.default
        var plans: [RenamePlan] = []
        for (i, u) in urls.enumerated() {
            let old = u.lastPathComponent
            let t = transform(old, index: i, rules: rules)
            var p = RenamePlan(url: u, oldName: old, newName: t.name, problem: t.error)
            if p.problem == nil {
                let base = (t.name as NSString).deletingPathExtension
                if t.name.trimmingCharacters(in: .whitespaces).isEmpty || base.isEmpty {
                    p.problem = "名称为空"
                } else if t.name.contains("/") {
                    p.problem = "名称不能包含“/”"
                } else if t.name.utf8.count > 255 {
                    p.problem = "名称太长"
                }
            }
            plans.append(p)
        }

        var counts: [String: Int] = [:]
        for p in plans {
            let key = p.url.deletingLastPathComponent().path + "/" + p.newName.lowercased()
            counts[key, default: 0] += 1
        }
        let selectedPaths = Set(urls.map { $0.standardizedFileURL.path.lowercased() })

        for i in plans.indices {
            if plans[i].problem != nil || !plans[i].changed { continue }
            let dir = plans[i].url.deletingLastPathComponent()
            let key = dir.path + "/" + plans[i].newName.lowercased()
            if counts[key, default: 0] > 1 {
                plans[i].problem = "与其他新名称重复"
                continue
            }
            let dest = dir.appendingPathComponent(plans[i].newName)
            let existsOnDisk = (try? fm.attributesOfItem(atPath: dest.path)) != nil
            if existsOnDisk && !selectedPaths.contains(dest.standardizedFileURL.path.lowercased()) {
                plans[i].problem = "已存在同名项目"
            }
        }
        return plans
    }

    /// 两阶段执行：先全部改成临时名，再改成目标名，这样 A→B、B→A 互换也不会冲突
    public static func execute(_ plans: [RenamePlan]) -> OpOutcome {
        var out = OpOutcome()
        let fm = FileManager.default
        let todo = plans.filter { $0.changed && $0.problem == nil }
        var staged: [(plan: RenamePlan, tmp: URL)] = []

        for p in todo {
            let tmp = p.url.deletingLastPathComponent().appendingPathComponent(".fp-\(UUID().uuidString).tmp")
            do {
                try fm.moveItem(at: p.url, to: tmp)
                staged.append((plan: p, tmp: tmp))
            } catch {
                out.failures.append("\(p.oldName)：\(error.localizedDescription)")
            }
        }
        for s in staged {
            let dest = s.plan.url.deletingLastPathComponent().appendingPathComponent(s.plan.newName)
            do {
                try fm.moveItem(at: s.tmp, to: dest)
                out.done.append(MovedPair(from: s.plan.url, to: dest))
            } catch {
                out.failures.append("\(s.plan.oldName)：\(error.localizedDescription)")
                try? fm.moveItem(at: s.tmp, to: s.plan.url)
            }
        }
        return out
    }
}
