#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

function die(message) {
  throw new Error(message);
}

function replaceOnce(source, searchValue, replacement) {
  const index = source.indexOf(searchValue);
  if (index === -1) {
    die(`Cannot find patch target: ${searchValue.slice(0, 80)}`);
  }
  return (
    source.slice(0, index) +
    replacement +
    source.slice(index + searchValue.length)
  );
}

function replaceRange(source, startMarker, endMarker, replacement) {
  const startIndex = source.indexOf(startMarker);
  if (startIndex === -1) {
    die(`Cannot find start marker: ${startMarker}`);
  }
  const endIndex = source.indexOf(endMarker, startIndex);
  if (endIndex === -1) {
    die(`Cannot find end marker: ${endMarker}`);
  }
  return (
    source.slice(0, startIndex) +
    replacement +
    source.slice(endIndex)
  );
}

function replaceIfPresent(source, searchValue, replacement) {
  const index = source.indexOf(searchValue);
  if (index === -1) {
    return source;
  }
  return (
    source.slice(0, index) +
    replacement +
    source.slice(index + searchValue.length)
  );
}

function parseArgs(argv) {
  const [
    asarDir,
    githubRepo,
    releaseTag,
    releaseDate,
    dmgName,
    archLabel,
  ] = argv;
  if (!asarDir || !githubRepo || !releaseTag || !releaseDate || !dmgName || !archLabel) {
    die(
      "Usage: patch-codex-desktop.mjs <asarDir> <githubRepo> <releaseTag> <releaseDate> <dmgName> <archLabel>",
    );
  }
  return {
    asarDir,
    githubRepo,
    releaseTag,
    releaseDate,
    dmgName,
    archLabel,
  };
}

function patchPackageJson(packageJsonPath, config) {
  const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, "utf8"));
  packageJson.codexIntelReleaseRepo = config.githubRepo;
  packageJson.codexIntelReleaseTag = config.releaseTag;
  packageJson.codexIntelReleaseDate = config.releaseDate;
  packageJson.codexIntelAssetName = config.dmgName;
  packageJson.codexIntelArch = config.archLabel;
  fs.writeFileSync(packageJsonPath, `${JSON.stringify(packageJson, null, 2)}\n`);
}

function patchBootstrap(bootstrapPath) {
  let source = fs.readFileSync(bootstrapPath, "utf8");
  if (source.includes("\"install-update\":`Install Update`")) {
    source = replaceOnce(
      source,
      "\"install-update\":`Install Update`",
      "\"install-update\":`Download Update`",
    );
  } else if (!source.includes("\"install-update\":`Download Update`")) {
    die(`Cannot find bootstrap update label in ${bootstrapPath}`);
  }
  source = replaceIfPresent(
    source,
    "detail:`Sparkle initialization skipped: ${n}`",
    "detail:`Updater initialization skipped: ${n}`",
  );
  fs.writeFileSync(bootstrapPath, source);
}

function buildUpdaterReplacement() {
  return [
    "getUpdater(){return this.sparkleUpdater}",
    "getIsUpdateReady(){return this.isUpdateReady}",
    "installUpdatesIfAvailable(){let e=this.latestDownloadUrl??this.latestReleasePageUrl;if(!e){G9().warning(`Release download request ignored (no update URL).`);return}try{this.isUpdateReady&&this.options.onInstallUpdatesRequested?.(),G9().info(`Opening release asset for update.`,{safe:{url:e},sensitive:{}}),f.shell.openExternal(e)}catch(t){G9().error(`Failed to open release asset`,{safe:{url:e},sensitive:{error:t}})}}",
    "getDiagnostics(){let e=this.buildDiagnostics();return{...e,latestReleaseTag:this.latestReleaseTag??null,latestDownloadUrl:this.latestDownloadUrl??null,latestReleasePageUrl:this.latestReleasePageUrl??null}}",
    "async initSparkleUpdater(){if(G9().info(`Release updater init begin`,{safe:{platform:process.platform,packaged:this.options.isPackaged},sensitive:{}}),process.platform!==`darwin`)return G9().info(`Release updater disabled: non-darwin platform.`),this.lastSkipReason=`non-darwin`,{updater:null};if(!this.options.isPackaged)return G9().info(`Release updater disabled in dev builds; use a production build to test updates.`),this.lastSkipReason=`dev build`,{updater:null};let e=this.resolveRepoConfig();if(!e)return{updater:null};this.lastSkipReason=null;let t=async()=>{await this.checkGitHubForUpdates(e)},n=async()=>{try{await t()}catch(r){G9().error(`Failed to check GitHub release updates`,{safe:{repo:e.repo},sensitive:{error:r}})}};let r=this.resolveIntervalMs();return r>0&&(G9().info(`Release updater scheduling interval (ms)`,{safe:{intervalMs:r},sensitive:{}}),setInterval(n,r).unref()),G9().info(`Release updater ready for manual checks.`,{safe:{repo:e.repo},sensitive:{}}),f.ipcMain.handle(`codex_desktop:check-for-updates`,async r=>{this.options.isTrustedIpcEvent(r)&&await t()}),await n(),{updater:{checkForUpdates:t}}}",
    "resolveRepoConfig(){let e=(uj(`codexIntelReleaseRepo`)?.trim()??``),t=(uj(`codexIntelReleaseTag`)?.trim()??``),n=(uj(`codexIntelReleaseDate`)?.trim()??``),r=(uj(`codexIntelAssetName`)?.trim()??``),i=(uj(`codexIntelArch`)?.trim()??`x64`);return e.length===0?(this.lastSkipReason=`missing github release repo`,G9().info(`No GitHub release repo configured; skipping updater.`),null):{repo:e,currentVersion:f.app.getVersion(),currentReleaseTag:t,currentReleaseDate:n,assetName:r,archLabel:i,releaseApiUrl:`https://api.github.com/repos/${e}/releases/latest`}}",
    "async checkGitHubForUpdates(e){G9().info(`Checking GitHub release updates.`,{safe:{repo:e.repo,releaseApiUrl:e.releaseApiUrl},sensitive:{}});let t=await f.net.fetch(e.releaseApiUrl,{headers:{Accept:`application/vnd.github+json`,\"User-Agent\":`CodexIntelUpdater`}});if(!t.ok)throw Error(`GitHub release check failed with status ${t.status}`);let n=await t.json(),r=this.extractReleaseInfo(n,e);if(!r)return this.isUpdateReady&&(this.isUpdateReady=!1,this.options.onUpdateReadyChanged?.(!1)),void(this.latestDownloadUrl=this.latestReleasePageUrl=this.latestReleaseTag=null);let i=this.isRemoteReleaseNewer(e,r);this.latestReleaseTag=r.tag,this.latestReleasePageUrl=r.releasePageUrl,this.latestDownloadUrl=r.downloadUrl;if(i){if(!this.isUpdateReady){this.isUpdateReady=!0,this.options.onUpdateReadyChanged?.(!0)}G9().info(`New GitHub release detected.`,{safe:{currentVersion:e.currentVersion,currentReleaseTag:e.currentReleaseTag,remoteTag:r.tag,downloadUrl:r.downloadUrl},sensitive:{}});return}this.isUpdateReady&&(this.isUpdateReady=!1,this.options.onUpdateReadyChanged?.(!1)),G9().info(`No newer GitHub release detected.`,{safe:{currentVersion:e.currentVersion,currentReleaseTag:e.currentReleaseTag,remoteTag:r.tag},sensitive:{}})}",
    "extractReleaseInfo(e,t){let n=typeof e.tag_name==`string`?e.tag_name.trim():``,r=/^v([0-9]+(?:\\.[0-9]+)+)-([A-Za-z0-9_]+)-([0-9]{8})$/.exec(n);if(!r)return G9().warning(`Latest release tag does not match expected pattern.`,{safe:{tag:n},sensitive:{}}),null;let i=Array.isArray(e.assets)?e.assets:[],a=t.assetName.length>0?i.find(e=>e&&typeof e.name==`string`&&e.name===t.assetName):null;a||(a=i.find(e=>e&&typeof e.name==`string`&&e.name.endsWith(`.dmg`)&&e.name.includes(`_${t.archLabel}_`)));let o=typeof e.html_url==`string`?e.html_url:null,s=typeof a?.browser_download_url==`string`?a.browser_download_url:o;return{tag:n,version:r[1],arch:r[2],releaseDate:r[3],downloadUrl:s,releasePageUrl:o}}",
    "compareVersionParts(e,t){let n=e.split(`.`).map(e=>Number(e)),r=t.split(`.`).map(e=>Number(e)),i=Math.max(n.length,r.length);for(let e=0;e<i;e+=1){let t=Number.isFinite(n[e])?n[e]:0,i=Number.isFinite(r[e])?r[e]:0;if(t!==i)return t>i?1:-1}return 0}",
    "isRemoteReleaseNewer(e,t){let n=this.compareVersionParts(t.version,e.currentVersion);if(n>0)return!0;if(n<0)return!1;let r=/^[0-9]{8}$/.test(e.currentReleaseDate),i=/^[0-9]{8}$/.test(t.releaseDate);return r&&i?t.releaseDate>e.currentReleaseDate:e.currentReleaseTag.length>0?t.tag!==e.currentReleaseTag:!1}",
    "resolveFeedUrl(){return(uj(`codexIntelReleaseRepo`)?.trim()??``)||(this.lastSkipReason=`missing github release repo`,null)}",
  ].join("");
}

function patchDeeplinks(deeplinksPath) {
  let source = fs.readFileSync(deeplinksPath, "utf8");
  source = replaceRange(
    source,
    "getUpdater(){return this.sparkleUpdater}",
    "buildDiagnostics(){return this.sparkleDiagnostics",
    buildUpdaterReplacement(),
  );
  fs.writeFileSync(deeplinksPath, source);
}

function buildModernUpdaterReplacement() {
  return [
    "async initializeMacSparkle(){if(process.platform!==`darwin`){this.lastUnavailableReason=`unsupported platform`;return}if(!this.options.isPackaged){this.lastUnavailableReason=`dev build`;return}let e=this.resolveMacSparkleFeedUrl();if(!e)return;let t={repo:e,currentVersion:p.app.getVersion(),currentReleaseTag:mj(`codexIntelReleaseTag`)?.trim()??``,currentReleaseDate:mj(`codexIntelReleaseDate`)?.trim()??``,assetName:mj(`codexIntelAssetName`)?.trim()??``,archLabel:mj(`codexIntelArch`)?.trim()??`x64`,releaseApiUrl:`https://api.github.com/repos/${e}/releases/latest`},n=async()=>{await this.checkGitHubForUpdates(t)};this.updater={checkForUpdates:n,installUpdatesIfAvailable:async()=>{let e=this.latestDownloadUrl??this.latestReleasePageUrl;if(!e){H9().warning(`Release download request ignored (no update URL).`);return}try{this.isUpdateReady&&this.options.onInstallUpdatesRequested?.(),H9().info(`Opening release asset for update.`,{safe:{url:e},sensitive:{}}),await p.shell.openExternal(e)}catch(t){H9().error(`Failed to open release asset`,{safe:{url:e},sensitive:{error:t}})}}},this.lastUnavailableReason=null;let r=W9();r>0&&setInterval(()=>{n().catch(e=>{H9().error(`Failed to check GitHub release updates`,{safe:{repo:t.repo},sensitive:{error:e}})})},r).unref(),await n().catch(e=>{H9().error(`Failed to check GitHub release updates`,{safe:{repo:t.repo},sensitive:{error:e}})})}",
    "resolveMacSparkleFeedUrl(){return(mj(`codexIntelReleaseRepo`)?.trim()??``)||(this.lastUnavailableReason=`missing github release repo`,null)}",
    "async checkGitHubForUpdates(e){H9().info(`Checking GitHub release updates.`,{safe:{repo:e.repo,releaseApiUrl:e.releaseApiUrl},sensitive:{}});let t=await p.net.fetch(e.releaseApiUrl,{headers:{Accept:`application/vnd.github+json`,\"User-Agent\":`CodexIntelUpdater`}});if(!t.ok)throw Error(`GitHub release check failed with status ${t.status}`);let n=await t.json(),r=this.extractReleaseInfo(n,e);if(!r)return this.setUpdateReady(!1),void(this.latestDownloadUrl=this.latestReleasePageUrl=this.latestReleaseTag=null);let i=this.isRemoteReleaseNewer(e,r);this.latestReleaseTag=r.tag,this.latestReleasePageUrl=r.releasePageUrl,this.latestDownloadUrl=r.downloadUrl,i?(this.setUpdateReady(!0),H9().info(`New GitHub release detected.`,{safe:{currentVersion:e.currentVersion,currentReleaseTag:e.currentReleaseTag,remoteTag:r.tag,downloadUrl:r.downloadUrl},sensitive:{}})):(this.setUpdateReady(!1),H9().info(`No newer GitHub release detected.`,{safe:{currentVersion:e.currentVersion,currentReleaseTag:e.currentReleaseTag,remoteTag:r.tag},sensitive:{}}))}",
    "extractReleaseInfo(e,t){let n=typeof e.tag_name==`string`?e.tag_name.trim():``,r=/^v([0-9]+(?:\\.[0-9]+)+)-([A-Za-z0-9_]+)-([0-9]{8})$/.exec(n);if(!r)return H9().warning(`Latest release tag does not match expected pattern.`,{safe:{tag:n},sensitive:{}}),null;let i=Array.isArray(e.assets)?e.assets:[],a=t.assetName.length>0?i.find(e=>e&&typeof e.name==`string`&&e.name===t.assetName):null;a||(a=i.find(e=>e&&typeof e.name==`string`&&e.name.endsWith(`.dmg`)&&e.name.includes(`_${t.archLabel}_`)));let o=typeof e.html_url==`string`?e.html_url:null,s=typeof a?.browser_download_url==`string`?a.browser_download_url:o;return{tag:n,version:r[1],arch:r[2],releaseDate:r[3],downloadUrl:s,releasePageUrl:o}}",
    "compareVersionParts(e,t){let n=e.split(`.`).map(e=>Number(e)),r=t.split(`.`).map(e=>Number(e)),i=Math.max(n.length,r.length);for(let e=0;e<i;e+=1){let t=Number.isFinite(n[e])?n[e]:0,i=Number.isFinite(r[e])?r[e]:0;if(t!==i)return t>i?1:-1}return 0}",
    "isRemoteReleaseNewer(e,t){let n=this.compareVersionParts(t.version,e.currentVersion);if(n>0)return!0;if(n<0)return!1;let r=/^[0-9]{8}$/.test(e.currentReleaseDate),i=/^[0-9]{8}$/.test(t.releaseDate);return r&&i?t.releaseDate>e.currentReleaseDate:e.currentReleaseTag.length>0?t.tag!==e.currentReleaseTag:!1}",
  ].join("");
}

function patchModernUpdaterBundle(bundlePath) {
  let source = fs.readFileSync(bundlePath, "utf8");
  source = replaceRange(
    source,
    "async initializeMacSparkle(){",
    "resolveWindowsUpdateUrl(){",
    buildModernUpdaterReplacement(),
  );
  fs.writeFileSync(bundlePath, source);
}

function resolveUpdaterBundlePath(asarDir) {
  const buildDir = path.join(asarDir, ".vite", "build");
  const bundleFiles = fs
    .readdirSync(buildDir)
    .filter((entry) => entry.endsWith(".js"))
    .sort();

  for (const file of bundleFiles) {
    const filePath = path.join(buildDir, file);
    const source = fs.readFileSync(filePath, "utf8");
    if (source.includes("getUpdater(){return this.sparkleUpdater}")) {
      return {
        filePath,
        patchKind: "legacy",
      };
    }
    if (source.includes("async initializeMacSparkle(){") && source.includes("resolveWindowsUpdateUrl(){")) {
      return {
        filePath,
        patchKind: "modern",
      };
    }
  }

  die(
    `Cannot find updater bundle in ${buildDir}; scanned files: ${bundleFiles.join(", ")}`,
  );
}

function patchUpdaterBundle(asarDir) {
  const updaterBundle = resolveUpdaterBundlePath(asarDir);
  if (updaterBundle.patchKind === "legacy") {
    patchDeeplinks(updaterBundle.filePath);
    return;
  }
  if (updaterBundle.patchKind === "modern") {
    patchModernUpdaterBundle(updaterBundle.filePath);
    return;
  }
  die(`Unsupported updater patch kind: ${updaterBundle.patchKind}`);
}

function resolveBootstrapPath(asarDir) {
  const bootstrapPath = path.join(asarDir, ".vite", "build", "bootstrap.js");
  if (!fs.existsSync(bootstrapPath)) {
    die(
      `Cannot find bootstrap bundle: ${bootstrapPath}`,
    );
  }
  return bootstrapPath;
}

function main() {
  const config = parseArgs(process.argv.slice(2));
  const packageJsonPath = path.join(config.asarDir, "package.json");
  const bootstrapPath = resolveBootstrapPath(config.asarDir);

  patchPackageJson(packageJsonPath, config);
  patchBootstrap(bootstrapPath);
  patchUpdaterBundle(config.asarDir);
}

main();
