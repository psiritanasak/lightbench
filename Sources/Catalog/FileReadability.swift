import Darwin
import Foundation

/// Why a file cannot be read, as far as one `open(2)` and one `stat(2)` can tell (IMPROVEMENTS.md D32). `CatalogModel.ensureAccessActive` used to
/// treat EVERY open failure of an existing file as "this sandbox lost its folder grant" and evicted the folder, started another security scope and
/// maybe showed a re-grant panel — none of which can help a file whose own permission bits forbid reading.
enum FileReadability: Equatable, Sendable {
    case readable
    /// The path does not exist (or a parent is not a directory).
    case missing
    /// `open` failed although the file's POSIX permission bits allow this user to read it: the only thing left is the sandbox, i.e. a lost or stale
    /// security-scoped grant. THIS is the case a re-grant can fix.
    case sandboxDenied
    /// `open` failed and the permission bits say this user may not read the file (a plain `chmod`): a re-grant cannot help.
    case posixDenied
    /// Any other failure (I/O error, too many open files, ...): not evidence of a lost grant.
    case otherFailure

    /// Pure classification, so it is testable without a sandbox. `openErrno` is nil when `open` succeeded. `mode`/`owner`/`group` come from
    /// `stat` (nil when `stat` itself failed). The permission-bit check ignores ACLs, which is deliberate: it only has to separate "bits forbid"
    /// from "bits allow but open still failed". (Known blind spots: ACLs, and `getgroups` can truncate at 16 groups on Darwin — both can only turn a
    /// sandbox denial into a false "plain chmod" for a file the user does not own.)
    static func classify(openErrno: Int32?, mode: mode_t?, owner: uid_t?, group: gid_t?, euid: uid_t, groups: [gid_t]) -> FileReadability {
        guard let openErrno else { return .readable }
        switch openErrno {
        case ENOENT, ENOTDIR: return .missing
        case EPERM, EACCES: break
        default: return .otherFailure
        }
        // `stat` failing with the same errors means even the metadata is off limits: that is the sandbox, not the file's bits.
        guard let mode, let owner, let group else { return .sandboxDenied }
        let bitsAllowRead: Bool
        if euid == 0 {
            bitsAllowRead = true
        } else if euid == owner {
            bitsAllowRead = mode & mode_t(S_IRUSR) != 0
        } else if groups.contains(group) {
            bitsAllowRead = mode & mode_t(S_IRGRP) != 0
        } else {
            bitsAllowRead = mode & mode_t(S_IROTH) != 0
        }
        return bitsAllowRead ? .sandboxDenied : .posixDenied
    }

    /// Opens `path` read-only (and closes it again) and classifies the outcome. May block on a slow volume: call off the main actor.
    static func probe(_ path: String) -> FileReadability {
        let fd = open(path, O_RDONLY)
        let openErrno: Int32? = fd >= 0 ? nil : errno
        if fd >= 0 { close(fd) }
        guard openErrno != nil else { return .readable }
        var info = stat()
        let statOK = stat(path, &info) == 0
        // The supplementary groups, sized by asking first (a fixed buffer can truncate). If they cannot be read, assume membership in the file's own
        // group: a false "plain chmod" verdict would skip a recovery that was needed, which is the costlier mistake.
        var groupList: [gid_t] = []
        let needed = getgroups(0, nil)
        if needed > 0 {
            var buffer = [gid_t](repeating: 0, count: Int(needed))
            let got = getgroups(needed, &buffer)
            if got >= 0 { groupList = Array(buffer.prefix(Int(got))) }
        }
        if groupList.isEmpty, statOK { groupList = [info.st_gid] }
        let groups = groupList
        return classify(openErrno: openErrno, mode: statOK ? info.st_mode : nil, owner: statOK ? info.st_uid : nil,
                        group: statOK ? info.st_gid : nil, euid: geteuid(), groups: groups)
    }
}
