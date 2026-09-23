// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import PS2ClassicsCore

struct ConsoleTransferView: View {
    @ObservedObject private var model = StudioModel.shared
    @State private var host=""
    @State private var port="21"
    @State private var folder="/dev_hdd0/packages"
    @State private var username="anonymous"
    @State private var password=""
    @State private var package:URL?
    @State private var runner:ConversionRunner?
    @State private var busy=false
    @State private var fraction=0.0
    @State private var message=""
    var body:some View {
        ScrollView { VStack(alignment:.leading,spacing:18) {
            Text("Send to PS3").font(.largeTitle.bold())
            Text("Transfer a completed package to your console’s FTP server. The app reads it back and checks every byte before reporting success.").foregroundColor(.secondary)
            HStack { TextField("Console address",text:$host); TextField("Port",text:$port).frame(width:80) }.disabled(busy)
            TextField("Destination folder",text:$folder).disabled(busy)
            HStack { TextField("Username",text:$username); SecureField("Password",text:$password) }.disabled(busy)
            Text("Login details stay in this view and are not saved. FTP is unencrypted; use a trusted local network.").font(.caption).foregroundColor(.secondary)
            Button("Choose package…") { package=model.chooseFile("Choose a completed PS2 Classics package.");message="" }.disabled(busy)
            Text(package?.lastPathComponent ?? "No package selected")
            Text("Each transfer creates a new PS2-… folder inside the destination. Use your console’s file manager to find and install package.pkg there. Folder support depends on the console’s FTP server.").font(.callout)
            if busy { ProgressView(value:fraction); Button("Cancel") {runner?.cancel()} }
            else { Button("Transfer and verify",action:send).disabled(package == nil || model.working) }
            Text(message).textSelection(.enabled)
        }.textFieldStyle(.roundedBorder).padding(30)
            .disabled(model.working && !busy)
        }
    }
    private func send() {
        guard let package else{return}
        do {
            guard let number=Int(port) else{throw ConversionFailure(message:"Enter a numeric port.")}
            let destination=try FTPDestination(host:host,port:number,directory:folder,username:username,password:password)
            let session=ConversionRunner(),helper=model.helperURL
            guard let token=model.beginUtility(.convert,cancel:{session.cancel()}) else{return}
            runner=session;busy=true;fraction=0;message="Checking package…"
            Task {
                do {
                    let path=try await Task.detached {
                        try ConsoleTransfer.send(package:package,destination:destination,helper:helper,runner:session) { update in
                            Task { @MainActor in guard busy, runner === session else{return};fraction=update.fraction;message=update.stage }
                        }
                    }.value
                    message="Transfer verified: \(path). Installation and launch have not been tested."
                } catch {message=error.localizedDescription}
                password="";busy=false;runner=nil;model.endUtility(token)
            }
        } catch {message=error.localizedDescription}
    }
}

struct OnlineConfigView: View {
    @ObservedObject private var model = StudioModel.shared
    @State private var address=""
    @State private var gameID=""
    @State private var message=""
    @State private var catalog:OnlineConfigCatalog?
    @State private var cachedAt: Date?
    @State private var runner:ConversionRunner?
    @State private var downloaded:URL?
    @State private var busy=false
    private static let date: DateFormatter = {
        let format=DateFormatter();format.dateStyle = .medium;format.timeStyle = .short
        return format
    }()
    var body:some View {
        ScrollView { VStack(alignment:.leading,spacing:16) {
            Text("Online CONFIG library").font(.largeTitle.bold())
            Text("Load a catalog from a publisher you trust, then review and download individual CONFIG files. Existing project selections stay unchanged.").foregroundColor(.secondary)
            HStack {
                TextField("HTTPS catalog address",text:$address).disabled(busy)
                    .onChange(of:address) { _ in refreshCacheNote() }
                Button("Load / refresh",action:fetch).disabled(busy || model.working)
            }
            .onAppear { refreshCacheNote() }
            if let cachedAt {
                HStack {
                    Text("Cached copy from \(Self.date.string(from:cachedAt)). Refresh only replaces it after another explicit load.").font(.caption)
                    Button("Use cached copy") { useCache() }.disabled(busy || model.working)
                    Button("Forget") { forgetCache() }.disabled(busy)
                }
            }
            Text("No public catalog is preselected. Publisher and license labels are supplied by the catalog; they are not an endorsement or proof of game compatibility.").font(.caption).foregroundColor(.secondary)
            if let catalog {
                Text(catalog.source).font(.headline)
                Text("Revision: \(catalog.revision) • License: \(catalog.license)").textSelection(.enabled)
                TextField("Exact game ID, e.g. SLUS12345",text:$gameID).disabled(busy)
                let matches=catalog.entries.filter{$0.gameID == gameID.uppercased()}
                Text("\(matches.count) matching CONFIGs. Enter the game ID shown in your project.").font(.caption)
                ForEach(matches.prefix(100)) { entry in
                    VStack(alignment:.leading,spacing:6) {
                        Text(entry.title.isEmpty ? entry.gameID : entry.title).font(.headline)
                        Text("\(entry.bytes) bytes • \(entry.url.host ?? "")").font(.caption)
                        Text(entry.sha256).font(.system(size:10,design:.monospaced)).textSelection(.enabled)
                        Button("Download verified copy…") {download(catalog,entry)}.disabled(busy || model.working)
                    }.padding(8)
                }
            }
            if busy {ProgressView();Button("Cancel"){runner?.cancel()}}
            Text(message).textSelection(.enabled)
            if let downloaded {
                Button("Show downloaded CONFIG") {NSWorkspace.shared.activateFileViewerSelecting([downloaded])}
                Text("Use Choose CONFIG in your project to select this copy, or point the local CONFIG library at its parent folder.").font(.caption)
            }
        }.textFieldStyle(.roundedBorder).padding(30) }
    }
    private func fetch() {
        guard let url=URL(string:address) else{message="Enter a direct HTTPS catalog address.";return}
        let session=ConversionRunner()
        guard let token=model.beginUtility(.convert,cancel:{session.cancel()}) else{return}
        busy=true;runner=session;message="Loading catalog…";catalog=nil;downloaded=nil
        Task {
            do {
                let loaded=try await Task.detached{try OnlineConfigCatalog.fetch(url,runner:session)}.value
                catalog=loaded;downloaded=nil
                if let encoded=try? JSONEncoder().encode(loaded) { try? OnlineCatalogCache.save(data:encoded,url:url) }
                refreshCacheNote()
                message="Catalog loaded. Review its publisher and matching entries."
            }
            catch {message=error.localizedDescription}
            busy=false;runner=nil;model.endUtility(token)
        }
    }
    private func refreshCacheNote() {
        guard let url=URL(string:address) else{cachedAt=nil;return}
        cachedAt=OnlineCatalogCache.load(url:url)?.retrievedAt
    }
    private func useCache() {
        guard let url=URL(string:address),
              let snapshot=OnlineCatalogCache.load(url:url) else{message="No cached copy for this address. Load it once while online.";return}
        catalog=snapshot.catalog;downloaded=nil
        message="Showing the cached copy retrieved \(Self.date.string(from:snapshot.retrievedAt)). Downloads still verify size and SHA-256. Refresh to check for updates."
    }
    private func forgetCache() {
        if let url=URL(string:address) { OnlineCatalogCache.remove(url:url) }
        refreshCacheNote();message="Cached copy removed."
    }
    private func download(_ catalog:OnlineConfigCatalog,_ entry:OnlineConfigCatalog.Entry) {
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.canCreateDirectories=true
        panel.message="Choose a local library folder. A new subfolder will hold the verified CONFIG and catalog receipt."
        guard panel.runModal() == .OK,let parent=panel.url else{return}
        let session=ConversionRunner()
        guard let token=model.beginUtility(.convert,cancel:{session.cancel()}) else{return}
        busy=true;runner=session;message="Downloading and checking CONFIG…";downloaded=nil
        Task {
            do {downloaded=try await Task.detached{try catalog.download(entry,into:parent,runner:session)}.value;message="Downloaded size and SHA-256 match the reviewed catalog."}
            catch{message=error.localizedDescription}
            busy=false;runner=nil;model.endUtility(token)
        }
    }
}
