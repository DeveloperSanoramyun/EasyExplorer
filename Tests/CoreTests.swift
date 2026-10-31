import Foundation

@main struct CoreTests {
    static var passed = 0
    static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw SafeFiles.error("FAILED: " + message) }
        passed += 1; print("PASS: " + message)
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FileExplorerTests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: "com.myungsan.fileexplorer.CoreTests")
        }
        func folder(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name); try fm.createDirectory(at: url, withIntermediateDirectories: true); return url
        }
        func write(_ url: URL, _ text: String) throws { try Data(text.utf8).write(to: url) }
        let same = try folder("same")
        let original = same.appendingPathComponent("original.txt"); try write(original, "valuable")
        let p1 = FileOperationProgress()
        let first = await FileOperationService.transfer([original], to: same, move: false, progress: p1, resolver: { _,_ in (.replace, false) })
        try expect(fm.fileExists(atPath: original.path) && first.count == 1, "same-folder copy preserves original and creates another item")
        let p2 = FileOperationProgress()
        let unchanged = await FileOperationService.transfer([original], to: same, move: true, progress: p2, resolver: { _,_ in (.replace, false) })
        try expect(unchanged.isEmpty && fm.fileExists(atPath: original.path), "same-folder move is a no-op")
        let src = try folder("src"), dst = try folder("dst")
        let old = dst.appendingPathComponent("data.txt"); try write(old, "old")
        let p3 = FileOperationProgress()
        _ = await FileOperationService.transfer([src.appendingPathComponent("data.txt")], to: dst, move: false, progress: p3, resolver: { _,_ in (.replace, false) })
        try expect(try String(contentsOf: old) == "old", "missing source never deletes destination")
        let source = src.appendingPathComponent("data.txt"); try write(source, "new")
        let p4 = FileOperationProgress()
        let replace = await FileOperationService.transfer([source], to: dst, move: false, progress: p4, resolver: { _,_ in (.replace, false) })
        try expect(try String(contentsOf: old) == "new" && replace.count == 1, "replace installs new file and records history")
        try replace[0].undo(); try expect(try String(contentsOf: old) == "old", "replace undo restores previous destination")
        try replace[0].redo(); try expect(try String(contentsOf: old) == "new", "replace redo preserves original backup")
        try write(old, "external replacement")
        var refusedChanged = false
        do { try replace[0].undo() } catch { refusedChanged = true }
        try expect(try refusedChanged && String(contentsOf: old) == "external replacement", "undo refuses externally changed file")
        let link = root.appendingPathComponent("link"); try fm.createSymbolicLink(at: link, withDestinationURL: src)
        let nested = src.appendingPathComponent("nested"); try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let p5 = FileOperationProgress()
        let recursive = await FileOperationService.transfer([src], to: link.appendingPathComponent("nested"), move: false, progress: p5, resolver: { _,_ in (.replace, false) })
        try expect(recursive.isEmpty, "symlink cannot bypass descendant protection")
        let cancel = OperationControl(); cancel.cancel()
        do { try SafeFiles.copy(source, to: root.appendingPathComponent("cancelled"), control: cancel); throw SafeFiles.error("Expected cancellation") }
        catch is CancellationError { try expect(true, "cancelled copy does not start") }
        let a = same.appendingPathComponent("A"), b = same.appendingPathComponent("B")
        try write(a, "A"); try write(b, "B")
        try BatchRenamer.apply([(a,b),(b,a)], control: OperationControl())
        try expect(try String(contentsOf: a) == "B" && String(contentsOf: b) == "A", "batch rename supports cycles")
        for name in ["", ".", "..", "a/b", "a\0b"] {
            var invalid = false
            do { try SafeFiles.validateName(name) } catch { invalid = true }
            try expect(invalid, "reject invalid name " + name.debugDescription)
        }
        let sizes = try folder("sizes")
        try fm.createDirectory(at: sizes.appendingPathComponent("Thing.app"), withIntermediateDirectories: true)
        try write(sizes.appendingPathComponent(".hidden"), "123")
        try write(sizes.appendingPathComponent("Thing.app/data"), "12345")
        try fm.linkItem(at: sizes.appendingPathComponent(".hidden"), to: sizes.appendingPathComponent("hardlink"))
        let measurement = FolderSizeService.measure(sizes)
        try expect(measurement.logical == 8, "folder size includes hidden/package files and deduplicates hardlinks")
        let scanned = SpotlightSearchService.scan("12345", scope: sizes, contents: true, control: OperationControl())
        // Content search intentionally skips packages; a normal nested file must be found.
        try write(sizes.appendingPathComponent("plain.txt"), "needle content")
        let content = SpotlightSearchService.scan("needle", scope: sizes, contents: true, control: OperationControl())
        try expect(content.urls.contains { $0.resolvingSymlinksInPath() == sizes.appendingPathComponent("plain.txt").resolvingSymlinksInPath() }, "recursive fallback finds local text contents")
        _ = scanned
        do { _ = try ProcessRunner.run("/usr/bin/yes", ["large output"], timeout: 0.2); throw SafeFiles.error("Expected timeout") }
        catch { try expect(error.localizedDescription.contains("timed out"), "large process output drains without deadlock and times out") }
        let rollback = try folder("rollback")
        let rollbackTarget = rollback.appendingPathComponent("existing.txt"); try write(rollbackTarget, "valuable rollback")
        let workspace = try SafeFiles.privateDirectory(in: rollback)
        var rolledBack = false
        do { _ = try SafeFiles.install(workspace.appendingPathComponent("absent"), at: rollbackTarget, replacing: FileIdentity(rollbackTarget), workspace: workspace) }
        catch { rolledBack = true }
        try expect(try rolledBack && String(contentsOf: rollbackTarget) == "valuable rollback", "failed final install restores previous destination")
        let raceStage = workspace.appendingPathComponent("new"); try write(raceStage, "new")
        let expected = try FileIdentity(rollbackTarget); try write(rollbackTarget, "changed externally")
        var raced = false
        do { _ = try SafeFiles.install(raceStage, at: rollbackTarget, replacing: expected, workspace: workspace) } catch { raced = true }
        try expect(try raced && String(contentsOf: rollbackTarget) == "changed externally", "destination change during staging is refused")
        let bytes = try ProcessRunner.run("/usr/bin/python3", ["-c", "import sys; sys.stdout.write('x'*2000000); sys.stderr.write('y'*2000000)"], timeout: 15)
        try expect(bytes.status == 0 && bytes.output.count == 1_048_576 && bytes.error.count == 1_048_576, "stdout and stderr both drain with bounded buffers")
        let big = src.appendingPathComponent("big.bin")
        fm.createFile(atPath: big.path, contents: nil)
        let bigHandle = try FileHandle(forWritingTo: big); try bigHandle.truncate(atOffset: 128 * 1024 * 1024); try bigHandle.close()
        let bigDest = dst.appendingPathComponent("big.bin"); try write(bigDest, "preserve me")
        let bigProgress = FileOperationProgress()
        let cancellation = Task.detached {
            let deadline = Date().addingTimeInterval(10)
            while bigProgress.control.bytes.done == 0 && Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
            await MainActor.run { bigProgress.cancel() }
        }
        _ = await FileOperationService.transfer([big], to: dst, move: false, progress: bigProgress, resolver: { _,_ in (.replace, false) })
        await cancellation.value
        try expect(try bigProgress.isCancelled && String(contentsOf: bigDest) == "preserve me", "mid-file cancellation preserves existing destination")
        let invalidPlanSource = same.appendingPathComponent("invalid-plan.txt"); try write(invalidPlanSource, "keep")
        let taken = same.appendingPathComponent("taken.txt"); try write(taken, "taken")
        var batchRefused = false
        do { try BatchRenamer.apply([(invalidPlanSource, taken)], control: OperationControl()) } catch { batchRefused = true }
        try expect(try batchRefused && String(contentsOf: invalidPlanSource) == "keep", "invalid batch plan leaves original names intact")
        let concurrentA = src.appendingPathComponent("concurrent-a"), concurrentB = src.appendingPathComponent("concurrent-b")
        try write(concurrentA, "A"); try write(concurrentB, "B")
        let progressA = FileOperationProgress(), progressB = FileOperationProgress()
        async let firstTransfer = FileOperationService.transfer([concurrentA], to: dst, move: false, progress: progressA, resolver: { _,_ in (.keepBoth, false) })
        async let secondTransfer = FileOperationService.transfer([concurrentB], to: dst, move: false, progress: progressB, resolver: { _,_ in (.keepBoth, false) })
        let counts = await (firstTransfer.count, secondTransfer.count)
        try expect(counts.0 == 1 && counts.1 == 1 && progressA.isDone && progressB.isDone, "two concurrent transfers finish through shared queue")
        guard CommandLine.arguments.count > 1 else { throw SafeFiles.error("Pass archive fixtures directory") }
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
        let archives = try folder("archives")
        for name in ["safe.zip", "traversal.zip", "absolute.zip", "symlink.zip", "hardlink.tar", "special.tar", "broken.zip"] {
            try fm.copyItem(at: fixtures.appendingPathComponent(name), to: archives.appendingPathComponent(name))
        }
        let existing = archives.appendingPathComponent("existing.txt"); try write(existing, "valuable existing")
        let extracted = try ArchiveService.extractOne(archives.appendingPathComponent("safe.zip"), control: OperationControl())
        try expect(try String(contentsOf: existing) == "valuable existing", "ZIP extraction never overwrites neighboring files")
        try expect(try String(contentsOf: extracted.appendingPathComponent("existing.txt")) == "archive data", "ZIP extracts inside its own new directory")
        let selected = try ArchiveService.extractOne(archives.appendingPathComponent("safe.zip"), control: OperationControl(), selected: ["nested"])
        try expect(fm.fileExists(atPath: selected.appendingPathComponent("nested/한자.txt").path) && !fm.fileExists(atPath: selected.appendingPathComponent("omit.txt").path), "archive selection extracts selected subtree only")
        let listed = try ArchiveService.list(archives.appendingPathComponent("safe.zip"))
        try expect(listed.count == 3, "archive browser lists entries without extracting")
        for name in ["traversal.zip", "absolute.zip", "symlink.zip", "hardlink.tar", "special.tar", "broken.zip"] {
            var rejected = false
            do { _ = try ArchiveService.extractOne(archives.appendingPathComponent(name), control: OperationControl()) }
            catch { rejected = true }
            try expect(rejected, "reject unsafe/damaged archive " + name)
        }
        var limited = false
        do { _ = try ArchiveService.extractOne(archives.appendingPathComponent("safe.zip"), control: OperationControl(), limits: .init(entries: 2, bytes: 100)) }
        catch { limited = true }
        try expect(limited, "archive entry-count quota is enforced")
        limited = false
        do { _ = try ArchiveService.extractOne(archives.appendingPathComponent("safe.zip"), control: OperationControl(), limits: .init(entries: 100, bytes: 4)) }
        catch { limited = true }
        try expect(limited, "archive expanded-byte quota is enforced")
        let batch = FileOperationProgress()
        await ArchiveService.extract([archives.appendingPathComponent("broken.zip"), archives.appendingPathComponent("safe.zip")], progress: batch)
        try expect(batch.isDone && batch.errorMessage != nil && batch.succeeded == 1 && batch.processed == 2, "multi-archive batch preserves earlier error through later success")
        let mergeSrc = try folder("merge-src"), mergeDst = try folder("merge-dst")
        let mergeFolder = mergeSrc.appendingPathComponent("Folder"), destFolder = mergeDst.appendingPathComponent("Folder")
        try fm.createDirectory(at: mergeFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
        try write(mergeFolder.appendingPathComponent("new.txt"), "new")
        try write(destFolder.appendingPathComponent("old.txt"), "old")
        let mergeProgress = FileOperationProgress()
        let merged = await FileOperationService.transfer([mergeFolder], to: mergeDst, move: false, progress: mergeProgress, resolver: { _,_ in (.merge, false) })
        try expect(merged.count == 1 && fm.fileExists(atPath: destFolder.appendingPathComponent("old.txt").path) && fm.fileExists(atPath: destFolder.appendingPathComponent("new.txt").path), "folder merge preserves destination-only children")
        let caseFile = src.appendingPathComponent("Case.txt"); try write(caseFile, "case")
        let caseURL = try FileOperationService.rename(caseFile, to: "case.txt")
        try expect(fm.fileExists(atPath: caseURL.path), "case-only rename works")
        let moving = src.appendingPathComponent("moving.txt"); try write(moving, "move")
        let moveProgress = FileOperationProgress()
        let moved = await FileOperationService.transfer([moving], to: dst, move: true, progress: moveProgress, resolver: { _,_ in (.replace, false) })
        try expect(moved.count == 1 && !fm.fileExists(atPath: moving.path), "move retires source only after successful destination commit")
        try moved[0].undo(); try expect(fm.fileExists(atPath: moving.path), "move Undo restores original path")
        try moved[0].redo(); try expect(!fm.fileExists(atPath: moving.path), "move Redo works")
        print("\(passed) core assertions passed.")

    }
}
