# User-supplied HTTPS CONFIG catalogs

RC8 supports explicit loading of a direct HTTPS JSON catalog (maximum 2 MiB). No default public feed or CONFIG payloads are distributed. Each download must also use direct HTTPS; credentials, URL fragments and redirects are disallowed. Publisher/revision/license fields are declarative labels, not independent licensing certification. Only a selected entry is downloaded, at most 1 MiB. Existing selected files are never updated silently.

Schema version 1:

```json
{
  "version": 1,
  "source": "Publisher name",
  "revision": "immutable release or commit identifier",
  "license": "publisher-declared data license",
  "entries": [
    {
      "gameID": "SLUS12345",
      "title": "Description of this CONFIG variant",
      "url": "https://publisher.example/immutable/SLUS12345.CONFIG",
      "sha256": "replace with the actual 64 lowercase hexadecimal digest",
      "bytes": 123
    }
  ]
}
```

The example is a schema illustration, not a working catalog. There may be 1–10,000 entries; game IDs must have four uppercase letters followed by five digits. Duplicate game-ID/digest pairs are rejected. Publisher, revision and license must be nonempty and at most 512 characters; titles are at most 256. Downloads must exactly match the advertised size/hash and must not have the encrypted PS2/NPD headers. Multiple variants may share a game ID if their digests differ.

A verified copy is saved in a fresh `CONFIG-UUID` folder, with `catalog.json` and `download.json` receipts. The latter records retrieval time, exact download URL, size and hash. The app does not send ROMs, support files, local paths or telemetry to the catalog server. The ordinary HTTPS request necessarily reveals the requesting IP to that server. Local-only use remains available.

Network execution uses macOS's system curl with its user configuration and proxy settings disabled, certificate verification enabled and bounded response reads. No network connection is made during startup or project loading. See the curl project's [option documentation](https://curl.se/docs/manpage.html) for the underlying transfer behavior.
