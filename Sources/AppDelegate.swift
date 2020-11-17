//
//  main.swift
//  MacDivvun
//
//  Created by Brendan Molloy on 3/10/16.
//  Copyright © 2016 Divvun. All rights reserved.
//

import Cocoa
import XCGLogger
import Sentry
import DivvunSpell

let userLibraryDir = try! FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
let macDivvunLogsPath = userLibraryDir
    .appendingPathComponent("Logs")
    .appendingPathComponent("MacDivvun")

let systemDest: AppleSystemLogDestination = {
    let x = AppleSystemLogDestination(identifier: "MacDivvun.system")
    x.outputLevel = .debug
    x.showFileName = false
    x.showLineNumber = false
    return x
}()

let fileDest: AutoRotatingFileDestination = {
    let x = AutoRotatingFileDestination(
        writeToFile: macDivvunLogsPath.appendingPathComponent("MacDivvun.log").path,
        identifier: "MacDivvun.file")
    x.showFileName = false
    x.showLineNumber = false
    x.outputLevel = .info
    x.logQueue = XCGLogger.logQueue
    return x
}()

internal let log: XCGLogger = {
    let x = XCGLogger(identifier: "MacDivvun", includeDefaultDestinations: false)

    x.add(destination: systemDest)
    x.add(destination: fileDest)
    x.logAppDetails()

    return x
}()


struct Global {
    static let vendor = "MacDivvun"
    static let paths = [
        "\(NSHomeDirectory())/Library/Services",
        "/Library/Services"
    ]
}

class MacDivvunRunner: NSApplication {
    private let appDelegate = AppDelegate()
    
    override init() {
        super.init()
        
        self.delegate = appDelegate
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

fileprivate func bundleFolderURLs() -> [URL] {
    return Global.paths.flatMap { path in
        FileManager.default.subpaths(atPath: path)?.filter {
            return $0.hasSuffix(".bundle")
        }.map {
            return URL(fileURLWithPath: "\(path)/\($0)", isDirectory: true)
        } ?? []
    }
}

func zhfstPaths(_ url: URL) -> [URL] {
    let rootPath = url.appendingPathComponent("Contents").appendingPathComponent("Resources")
    return (try? FileManager.default.contentsOfDirectory(atPath: rootPath.path))?.filter {
        return $0.hasSuffix(".zhfst")
    }.map {
        return URL(fileURLWithPath: "\(rootPath.path)/\($0)")
    } ?? []
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    let delegate = SpellServerDelegate()
    let server = NSSpellServer()
    var watcher: BundlesWatcher!
    
    func flushAndUpdate() {
        log.info("Flushing and updating speller cache")
        NSSpellServer.flushCache()
        NSSpellServer.updateCache()
    }
    
    func registerBundle(at path: URL) {
        log.info("Loading bundle: \(path.path)")

        let filePaths = zhfstPaths(path)
        log.debug("zhfsts: \(filePaths.map { $0.absoluteString }.joined(separator: ", "))")

        for filePath in filePaths {
            let archive: HfstZipSpellerArchive
            let speller: HfstZipSpeller
            do {
                archive = try HfstZipSpellerArchive.open(path: filePath.path)
                speller = try archive.speller()
            } catch {
                log.error("Error loading: \(filePath.path)")
                if let error = error as? DivvunSpellError {
                    log.debug(error.message)
                }
                return
            }

            let locale = filePath.deletingPathExtension().lastPathComponent
            
            self.delegate.spellers[locale] = speller
            log.info("Added speller: \(filePath.path) with locale '\(locale)'")
            
            server.registerLanguage(archive.locale, byVendor: Global.vendor)
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        server.delegate = delegate

        SentrySDK.start { options in
            if let dsn = Bundle.main.infoDictionary!["SENTRY_DSN"] as? String {
                options.dsn = dsn
            }
            options.debug = true
            options.enableAutoSessionTracking = true
        }
        log.info("Sentry started.")


        log.info("Bundle paths: \(Global.paths.joined(separator: ", "))")


        let bundles = bundleFolderURLs()
        bundles.forEach(registerBundle(at:))
        
        watcher = BundlesWatcher {
            self.registerBundle(at: URL(fileURLWithPath: $0))
        }
        watcher.start()
        log.info("Bundle watcher started; new spellers will be added.")
        
        log.info("\(Global.vendor) started")
        self.server.run()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        log.info("\(Global.vendor) stopped")
    }
}
