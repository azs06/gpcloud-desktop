# GP Cloud API: reverse-engineering notes

Sources:
- the logged-in web app at `gpcloud.grameenphone.com` (Next.js + NextAuth, RTK Query), bundles and live traffic
- the Android app `com.grameenphone.gpcloud` v1.0.5 (build 154), decompiled with jadx

The flows marked ✅ were exercised live against a real account on 2026-11-12.

Backend: a Spring Boot service (`com.galaxy.gpcloud`) behind the API gateway `aloapis.grameenphone.com/apigw/...`. File storage is **Huawei Drive Kit**, so you see Huawei-style IDs, `application/vnd.huawei-apps.folder`, and presigned **Huawei OBS** URLs (`*.obs.ap-southeast-3.myhuaweicloud.com`).

## Base URLs

| Client  | Base                                                       |
|---------|------------------------------------------------------------|
| Web     | `https://gpcloud.grameenphone.com/api/gateway` (same-origin Next.js proxy) |
| Android | `https://aloapis.grameenphone.com/apigw`                   |

Paths below are relative to those bases: the web strips `/apigw`, so `/apigw/gpcloud/edge/api/v1/files` becomes `/api/gateway/gpcloud/edge/api/v1/files`.

Response envelope (every endpoint):
```json
{ "data": …, "success": true, "code": 200, "status": "OK", "message": "…", "errorMessages": [{"message": "…", "details": "…"}], "pageInfo": {…} }
```
The gateway answers **401 with an empty body for routes it doesn't know**, and 401 + JSON `"Authentication required"` for a missing or expired token.

## Auth

### Web (what the Mac app uses) ✅
1. The user signs in on `gpcloud.grameenphone.com` through NextAuth. Internally the page calls the OAuth endpoints below through `/api/core-proxy/public/oauth/*` with the web `X-CLIENT-ID`, scope `GP_CLOUD`.
2. NextAuth stores an HttpOnly session cookie.
3. `GET /api/auth/session` returns `{ user: {id, companyId, products, accessMatrix}, expires, accessToken }`. NextAuth refreshes `accessToken` server-side; `session.error === "RefreshTokenError"` means you must sign in again.
4. Every gateway call: `Authorization: Bearer <accessToken>`. The web client also sends `X-APP-NAME: GP Cloud`, `X-APP-VERSION: 0.1.0`, `X-APP-PACKAGE-NAME`, `X-DEVICE-ID` (a random UUID kept in `localStorage["device-id"]`), `X-DEVICE-VENDOR`, `X-DEVICE-MODEL`, `X-DEVICE-OS-VERSION`. Only the bearer token is actually required.

### Mobile (native OAuth + PKCE). Documented from the APK, not exercised.
All requests carry `X-CLIENT-ID: cc328f377254309e0d719a601edca597`.

| Step | Request | Body | Notes |
|---|---|---|---|
| 0 | `POST /apigw/core/edge/public/oauth/identifier-availability` | `{identifier}` | → `{available, flow, userStatus}` |
| 1 | `POST /apigw/core/edge/public/oauth/login` | `{identifier, password}` | → `data.token`, `isTwoFactorEnabled`, `mfaMethod` |
| 2 | `POST /apigw/core/edge/public/oauth/verify-2fa` | `{code}` | `Authorization: Bearer <login token>` |
| 3 | `POST /apigw/core/edge/public/oauth/authorize` | `{redirectUri:"gpcloud://oauth/callback", clientId, codeChallengeMethod:"S256", codeChallenge, scope:"GPCLOUD_ACCESS"}` | Bearer = temp token → `data.code` |
| 4 | `POST /apigw/core/edge/public/oauth/get-access-token` | `{grantType:"authorization_code", clientId, code, codeVerifier, redirectUri, device_id, platform:"ANDROID", device_model, device_name, os_version, app_version, app_build_number}` | → `{accessToken, refreshToken, expiresIn, tokenType}` |
| ↻ | `POST /apigw/core/edge/public/oauth/get-refresh-token` | `{grantType:"refresh_token", refreshToken, clientId, codeVerifier:<fresh random>}` | |
| ✕ | `POST /apigw/core/edge/api/v1/oauth/revoke-session` | | sign out |

Signup, forgot-password and password-setup flows live under `/apigw/core/edge/public/oauth/{signup,forget-password,web-handoff/password-setup}/{send-otp,verify-otp,set-password}`.

## Files (`/gpcloud/edge/api/v1`)

| Op | Request | Body | Live |
|---|---|---|---|
| Root folder | `GET /files/root` | | ✅ |
| File details (+ fresh download links) | `GET /files/{id}` | | ✅ |
| List folder | `POST /files` | `{parentFolderId:"root"\|id, recycled:false, pageInfo:{pageSize, pageCursor?}, sortInfo?:{sortBy, sortOrder}, fileType?}` → `data.files[]`, `data.nextPageCursor` | ✅ |
| Trash | `POST /files` | `{recycled:true, pageInfo:{…}}` | ✅ |
| Search | `POST /files/search` | `{keyWord, recycled:false, pageInfo, parentFolderId?, fileType?, searchType?}` | ✅ |
| Starred | `POST /files/favorite` | `{pageSize, pageCursor?, fileType?, sortOrder?}` | ✅ |
| Star / unstar | `PUT /files/favorite/mark-favorite` | `{items:[id], favorite:bool}` | ✅ |
| Recent activity | `GET /files/recent` | → `files[].{action, actionAt, metadata:{fileId,fileName,fileType}}` | ✅ |
| New folder | `POST /files/create/folder` | `{name, parentFolder:"root"\|id}` → `{id, folderName}` | ✅ |
| Rename | `PUT /files/rename/{id}` | `{newName, duplicateFilePolicy:"FORCE_RENAME"}`. Send the base name only; the server re-appends `fileSuffix` | ✅ |
| Move | `PUT /files/move` | `{items:[{fileId}], newFilePath:<destination folder id>}` | ✅ |
| Copy | `POST /files/copy` | same as move | |
| Trash / delete | `DELETE /files/delete` (with body) | `{items:[{fileId, filePath:"<parentId\|root>/<fileId>"}], policy:"LOGICAL"\|"PERMANENT"}` | ✅ LOGICAL |
| Restore | `POST /files/restore` | `{items:[id]}` | ✅ |
| Empty trash | `DELETE /files/trash-empty` | | |
| Public link | `POST /files/share/public` | `{item:id, validity:int}` → `{shareId, shortUrl, expireAt}` | |

sortBy values: `FILE_NAME`, `UPDATE_TIME`, `CREATE_TIME`, `RECYCLED_TIME`, `FILE_SUFFIX`, `SIZE`; sortOrder: `ASC`/`DESC`.
fileType values: `FOLDER`, `SMART_FOLDER`, `PICTURE`, `VIDEO`, `WORD`, `EXCEL`, `PPT`, `AUDIO`, `ARCHIVE`, `APPLICATION`, `COMPRESSED`, `OTHER`.

**Name rule** (server-side regex): `^(?!\.{1,2}$)(?!.*[<>|:"*?\/\s]).{1,250}$`, so **no spaces**. The Android app strips `<>|:"*?/\` and spaces from upload names.

**Timestamps**: `createdTime`/`editedTime` are UTC without a zone suffix; `recent[].actionAt` is Asia/Dhaka local time.

**File object**: `id, fileName, fileType, fileSuffix, mimeType, parentFolder[], fileSize, recycled, favorite, createdTime, editedTime, userCapabilities{…}, downloadLinks[{usage:"content"|"thumbnail", downloadLink}]`. The download links are presigned OBS GETs, so no auth header is needed. They expire, so fetch `GET /files/{id}` right before downloading.

## Account

- `GET /gpcloud/edge/api/v1/profile/user-space-info/1` → `{cloudUserId, capacity, spaceUsed, lastUpdatedAt}` ✅
- `GET /gpcloud/edge/api/v1/profile/space-metrics` → totals plus a per-type breakdown ✅
- `GET /iam/edge/api/v1/users/profile` → `{id, name, firstName, lastName, email, mobileNumber, userName, enableMfa, …}`
- `GET /gpcloud/edge/api/v1/subscription/profile`, `…/subscription/subscription-profile`, `…/subscription/product-bundles`

## Upload ✅ (single-slice and 2-slice files verified; sizes match after download)

The web app has **no upload**. Its button only shows "install the mobile app". The protocol comes from the APK.

```
client                                     GP Cloud                      Huawei OBS
  │ hash file locally                          │                              │
  │ POST /files/create-file-meta ────────────► │                              │
  │ ◄──── {fileId, uploadId, rapidUpload, multiParts[{partNumber, partOffset, partSize, uploadUrl}]}
  │ PUT uploadUrl (each slice, octet-stream) ─────────────────────────────────► │  200 + ETag
  │ GET /files/complete-status/{fileId} ─────► │  success                     │
```

### create-file-meta body
```json
{
  "duplicateFilePolicy": "FORCE_RENAME",          // or REJECT, CHECK_SHA_OR_FORCE
  "fileName": "photo.jpg",
  "fileType": "PICTURE",
  "mimeType": "image/jpeg",
  "parentFolder": ["root"],                        // or a folder id
  "totalSize": 6291579,
  "sha256": "<hex sha256 of whole file>",
  "proofCode": "<see below>",
  "uploadMode": "multipart",
  "uploadType": "MULTIPART",
  "multiParts": [
    { "partNumber": 1, "partOffset": 0,       "partSize": 5242880, "hashCtx": ["1779033703", "3144134277", …8 values] },
    { "partNumber": 2, "partOffset": 5242880, "partSize": 1048699, "hashCtx": [ …midstate after 5 MiB… ] }
  ]
}
```

### Slicing
Slice size depends on file size (rounded down to a multiple of 64 bytes):

| file size | ≤100 MB | ≤500 MB | ≤2 GB | ≤5 GB | ≤10 GB | >10 GB |
|---|---|---|---|---|---|---|
| slice | 5 MB | 8 MB | 10 MB | 50 MB | 100 MB | 200 MB |

`hashCtx` for slice *n* is the **SHA-256 internal state (the 8 chaining words h0…h7, as unsigned decimal strings) after hashing all bytes before that slice**. For slice 1 that is the SHA-256 IV. The Android app computes it with a native `libgpcloud_sha256` (`nativeMidstate`). On macOS, `CC_SHA256_CTX.hash` holds exactly these words after block-aligned updates.

### proofCode
```
seed   = hex(sha256(utf8(cloudUserId)))            // cloudUserId from user-space-info
d      = sha256(utf8(seed)); d[24] &= 0x7f
off    = int64_be(d[24..<32]); if off > size { off %= size }
proof  = hex(sha256(file[off ..< min(off+8, size)]))
```
This lets the server verify possession for dedup ("rapid upload"). If `rapidUpload` is true, nothing needs to be PUT.

## Download ✅
`GET /files/{id}` → `downloadLinks[usage=="content"].downloadLink` → plain GET (presigned). `usage=="thumbnail"` returns a resized image via `x-image-process`.
