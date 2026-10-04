#!/usr/bin/env python3
"""Private, offline validation and cleanup for the manual signing workflow.

Never print certificate, profile, private-key contents, or tool diagnostics.
Only the commands that explicitly return a UUID/fingerprint emit those values.
"""
import base64
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys

UUID = r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}"


class ValidationError(Exception):
    """A hand-written diagnostic that never includes parsed secret material."""


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def load_plist(path):
    return plistlib.loads(Path(path).read_bytes())


def preflight(action, build):
    require(action in ("archive", "upload"), "Action must be archive or upload")
    require(re.fullmatch(r"[1-9][0-9]{0,3}", build), "Build number must be an integer from 1 to 9999")
    spec = importlib.util.spec_from_file_location("pilot_config", Path(__file__).with_name("validate-pilot-config.py"))
    config = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(config)
    env = dict(os.environ, ARRIVAU_BUILD_NUMBER=build)
    try:
        config.validate_archive(env)
    except ValueError as error:
        # This existing validator emits only static, hand-written configuration diagnostics.
        raise ValidationError(str(error)) from None
    required = ["APPLE_DISTRIBUTION_P12_BASE64", "APPLE_DISTRIBUTION_P12_PASSWORD", "APPLE_APP_STORE_PROFILE_BASE64"]
    if action == "upload":
        required += ["ASC_PRIVATE_KEY_BASE64", "ASC_KEY_ID", "ASC_ISSUER_ID"]
    for name in required:
        require(bool(env.get(name)), f"Missing required secret: {name}")
    if action == "upload":
        require(re.fullmatch(r"[A-Z0-9]{10}", env["ASC_KEY_ID"]), "ASC_KEY_ID must be a ten-character team API key ID")
        require(re.fullmatch(UUID, env["ASC_ISSUER_ID"]), "ASC_ISSUER_ID must be a UUID for the team API key")


def decode(secret_name, output):
    try:
        value = base64.b64decode("".join(os.environ[secret_name].split()), validate=True)
    except (KeyError, ValueError) as error:
        raise ValidationError(f"Invalid Base64 secret: {secret_name}") from error
    require(bool(value), f"Empty decoded secret: {secret_name}")
    with Path(output).open("xb") as target:
        target.write(value)
    Path(output).chmod(0o600)


def validate_profile(path):
    profile = load_plist(path)
    team, bundle = os.environ["ARRIVAU_TEAM_ID"], os.environ["ARRIVAU_BUNDLE_ID"]
    entitlements = profile.get("Entitlements", {})
    now = dt.datetime.now(dt.timezone.utc)
    expires = profile.get("ExpirationDate")
    require(isinstance(expires, dt.datetime), "Provisioning profile has no expiration date")
    require(expires.replace(tzinfo=dt.timezone.utc) > now, "Provisioning profile has expired")
    require(profile.get("TeamIdentifier") == [team], "Provisioning profile belongs to a different team")
    require(entitlements.get("com.apple.developer.team-identifier") == team, "Profile team entitlement differs")
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    app_id = entitlements.get("application-identifier")
    require(any(app_id == f"{prefix}.{bundle}" for prefix in prefixes if isinstance(prefix, str)),
            "Profile must explicitly match the bundle ID (wildcard profiles are rejected)")
    require("iOS" in profile.get("Platform", []), "Provisioning profile is not for iOS")
    require("ProvisionedDevices" not in profile and not profile.get("ProvisionsAllDevices", False),
            "Use an App Store distribution profile, not development, Ad Hoc, or enterprise")
    require(entitlements.get("get-task-allow") is False and entitlements.get("beta-reports-active") is True,
            "Profile must have App Store distribution entitlements")
    require(re.fullmatch(UUID, profile.get("UUID", "")), "Provisioning profile UUID is invalid")
    certificates = profile.get("DeveloperCertificates", [])
    require(certificates and all(isinstance(cert, bytes) and cert for cert in certificates),
            "Profile has no signing certificates")
    return profile


def identity(profile_path, identities_path):
    profile = validate_profile(profile_path)
    permitted = {hashlib.sha1(cert).hexdigest().upper() for cert in profile["DeveloperCertificates"]}
    found = []
    for fingerprint, name in re.findall(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"([^"\n]+)"\s*$',
                                         Path(identities_path).read_text(), re.MULTILINE):
        if (fingerprint.upper() in permitted and name.startswith("Apple Distribution:")
                and name.endswith(f"({os.environ['ARRIVAU_TEAM_ID']})")):
            found.append(fingerprint.upper())
    require(len(found) == 1, "Expected exactly one valid imported Apple Distribution identity matching the profile")
    return found[0]


def export_options(profile_path, fingerprint, destination):
    profile = validate_profile(profile_path)
    require(re.fullmatch(r"[A-F0-9]{40}", fingerprint), "Invalid signing certificate fingerprint")
    options = {
        "method": "app-store-connect", "destination": "export", "signingStyle": "manual",
        "teamID": os.environ["ARRIVAU_TEAM_ID"], "signingCertificate": fingerprint,
        "provisioningProfiles": {os.environ["ARRIVAU_BUNDLE_ID"]: profile["UUID"]},
        "manageAppVersionAndBuildNumber": False, "stripSwiftSymbols": True, "uploadSymbols": False,
    }
    Path(destination).write_bytes(plistlib.dumps(options))


def verify_app(app_path, profile_path, entitlements_path, signature_path, build, fingerprint, leaf_path):
    app = Path(app_path)
    info, profile, entitlements = load_plist(app / "Info.plist"), validate_profile(profile_path), load_plist(entitlements_path)
    require(info.get("CFBundleIdentifier") == os.environ["ARRIVAU_BUNDLE_ID"], "Actual bundle ID differs")
    require(info.get("CFBundleVersion") == build, "Actual bundle build number differs")
    require(info.get("ARRIVAU_API_URL") == os.environ["ARRIVAU_API_URL"], "Actual API origin differs")
    require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "Actual bundle is not an iOS device build")
    require(entitlements.get("application-identifier") == profile["Entitlements"]["application-identifier"],
            "Signed application identifier differs from profile")
    require(entitlements.get("com.apple.developer.team-identifier") == os.environ["ARRIVAU_TEAM_ID"],
            "Signed team entitlement differs")
    require(entitlements.get("get-task-allow") is False, "Signed app allows debugging")
    signature = Path(signature_path).read_text()
    require(f"TeamIdentifier={os.environ['ARRIVAU_TEAM_ID']}" in signature.splitlines(), "Actual signing team differs")
    require(hashlib.sha1(Path(leaf_path).read_bytes()).hexdigest().upper() == fingerprint,
            "Actual signing certificate differs from the imported identity")


def init_state(work):
    state = {"keychain": str(work / "signing.keychain-db"), "profile": None, "original_keychains": None}
    (work / "state.json").write_text(json.dumps(state))


def change_state(work, key, value):
    path = work / "state.json"
    state = json.loads(path.read_text())
    state[key] = value
    replacement = work / "state.next.json"
    replacement.write_text(json.dumps(state))
    replacement.replace(path)


def profile_install(work, uuid):
    require(re.fullmatch(UUID, uuid), "Invalid profile UUID")
    directory = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / f"{work.name}-{uuid}.mobileprovision"
    require(not target.exists(), "Temporary profile path already exists")
    change_state(work, "profile", str(target))
    with target.open("xb") as output:
        output.write((work / "profile.mobileprovision").read_bytes())
    target.chmod(0o600)


def save_keychains(work, raw_path):
    keychains = shlex.split(Path(raw_path).read_text())
    require(keychains and all("\n" not in p for p in keychains), "Could not read original keychain search list")
    change_state(work, "original_keychains", keychains)
    print("\n".join(keychains))


def cleanup(work):
    # Only remove our unique directory, keychain, and exact profile; never use broad globs.
    root = Path(os.environ["RUNNER_TEMP"]).resolve()
    require(work.parent.resolve() == root and re.fullmatch(r"arrivau-testflight\.[0-9]+\.[0-9]+\.[A-Za-z0-9]+", work.name),
            "Refusing cleanup outside the job's temporary directory")
    if not work.exists():
        return
    require(not work.is_symlink(), "Refusing to follow a temporary-directory symlink")
    def private_security(*args):
        try:
            return subprocess.run(["security", *args], stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, check=False).returncode == 0
        except (OSError, ValueError, TypeError):
            return False

    ok = True
    try:
        state_path = work / "state.json"
        state = json.loads(state_path.read_text()) if state_path.exists() else {}
        if state.get("original_keychains"):
            ok = private_security("list-keychains", "-d", "user", "-s", *state["original_keychains"])
        keychain = work / "signing.keychain-db"
        if keychain.exists():
            ok = private_security("delete-keychain", str(keychain)) and ok
        if state.get("profile"):
            profile = Path(state["profile"])
            expected = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
            require(profile.parent == expected and
                    re.fullmatch(re.escape(work.name) + "-" + UUID + r"\.mobileprovision", profile.name),
                    "Refusing unexpected profile cleanup path")
            profile.unlink(missing_ok=True)
    except (ValidationError, OSError, ValueError, TypeError, AttributeError):
        ok = False
    finally:
        # Even failed restoration must not prevent deletion of credentials/build products.
        try:
            shutil.rmtree(work)
        except OSError:
            ok = False
    require(ok, "Temporary signing cleanup could not be verified; inspect the runner before reusing it")



def main(args):
    command, *values = args
    if command == "preflight":
        preflight(*values)
    elif command == "decode":
        decode(*values)
    elif command == "profile":
        print(validate_profile(*values)["UUID"])
    elif command == "identity":
        print(identity(*values))
    elif command == "export-options":
        export_options(*values)
    elif command == "verify-app":
        verify_app(*values)
    elif command == "init-state":
        init_state(Path(values[0]))
    elif command == "install-profile":
        profile_install(Path(values[0]), values[1])
    elif command == "save-keychains":
        save_keychains(Path(values[0]), values[1])
    elif command == "cleanup":
        cleanup(Path(values[0]))
    else:
        raise ValueError("Unknown signing helper command")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except ValidationError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from None
    except Exception:
        # Parsers and OS errors can echo private input. Never emit their messages or tracebacks.
        print("Signing input or temporary-file validation failed", file=sys.stderr)
        raise SystemExit(1) from None
