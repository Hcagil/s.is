#!/usr/bin/env python3
"""Stand-ins for the macOS tools the iOS workflow calls, for
test/tool/ios_release_test.sh. One file, dispatched on the name it is run as
(the test symlinks codesign, security, xcodebuild, xcrun, plutil, curl and
openssl to it). Each accepts the real tool's option surface for what it
models; a call the real tool would refuse is logged to $STUB_REJECTS and
exits 2, so the test fails on it.

Modelled behaviour, as the real tools have it:
- codesign signs with an identity found by SHA-1 in the keychain search list
  (certificate + matching private key + partition list + a chain to the
  root), or ad-hoc (`-`). A designated requirement it or Xcode generates pins
  the certificate's common name in NFD form, while the certificate holds it
  in NFC: for a team name with non-ASCII letters such a requirement is never
  satisfied (the defect the explicit requirement works around). Signing a
  bundle seals its nested frameworks; re-signing a framework afterwards
  breaks the seal. A bundle with unsigned nested code cannot be signed.
- xcodebuild archives only unsigned (CODE_SIGNING_ALLOWED = NO) - signed, it
  would need a development profile and the team has no device - and exports
  with manual signing: identity by SHA-1, profile by UUID from the user's
  Provisioning Profiles directory; the exported app keeps the entitlements
  the archived app was signed with (none if unsigned), with the profile's
  values (aps-environment) put over them.
- security keeps keychains as files and a per-user search list; a
  mobileprovision is "STUBCMS\\n" + plist (`cms -D` strips the wrapper).
- altool validates/uploads only an .ipa whose app and every framework are
  signed by an Apple Distribution certificate and satisfy their designated
  requirement, with the API key found in API_PRIVATE_KEYS_DIR.
- openssl is the real one, refusing options LibreSSL 3.3 (macOS
  /usr/bin/openssl) does not have.

Signature state lives in BUNDLE/_CodeSignature/stub.json, so it survives
zip/unzip like a real signature.
"""
import glob
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import unicodedata
import zipfile

TOOL = os.path.basename(sys.argv[0])
ARGS = sys.argv[1:]
E = os.environ
OPENSSL = E.get("REAL_OPENSSL", "/usr/bin/openssl")


def reject(msg):
    line = "%s %s" % (TOOL, " ".join(ARGS))
    print("%s stub: %s (call: %s)" % (TOOL, msg, line), file=sys.stderr)
    with open(E["STUB_REJECTS"], "a") as f:
        f.write(line + "\n")
    sys.exit(2)


def die(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def record(line):
    with open(E["STUB_CALLS"], "a") as f:
        f.write(line + "\n")


def ossl(*a, data=None):
    return subprocess.run([OPENSSL, *a], input=data, capture_output=True)


# ---- certificates and keychains ------------------------------------------------
def to_der(data):
    fmt = [] if b"-----BEGIN CERTIFICATE" in data else ["-inform", "der"]
    p = ossl("x509", *fmt, "-outform", "der", data=data)
    return p.stdout if p.returncode == 0 and p.stdout else None


def names(der, which):
    out = ossl("x509", "-inform", "der", "-noout", "-" + which, "-nameopt",
               "utf8,sep_multiline,-esc_msb,sname,space_eq", data=der).stdout.decode()
    d = {}
    for line in out.splitlines()[1:]:
        k, _, v = line.strip().partition(" = ")
        d[k] = v
    return d


def cert_info(der):
    return {"sha1": hashlib.sha1(der).hexdigest().upper(), "subject": names(der, "subject"),
            "issuer": names(der, "issuer"),
            "pub": ossl("x509", "-inform", "der", "-noout", "-pubkey", data=der).stdout.decode()}


def search_file():
    return os.path.join(E["HOME"], ".stub-keychain-search")


def search_list():
    try:
        with open(search_file()) as f:
            return json.load(f)
    except FileNotFoundError:
        return [os.path.join(E["HOME"], "Library/Keychains/login.keychain-db")]


def kc_load(path):
    with open(path) as f:
        return json.load(f)


def kc_save(path, kc):
    with open(path, "w") as f:
        json.dump(kc, f)


def searched_certs():
    for kc in search_list():
        if os.path.exists(kc):
            for c in kc_load(kc)["certs"]:
                yield bytes.fromhex(c)


def chains_to_root(info):
    root = E["STUB_ROOT_CN"]
    if info["issuer"].get("CN") == root:
        return True
    for der in searched_certs():
        i = cert_info(der)
        if i["subject"].get("CN") == info["issuer"].get("CN") and i["issuer"].get("CN") == root:
            return True
    return False


def identity(spec):
    """(info, der) of the signing identity SPEC (a SHA-1), or exits as codesign/xcodebuild do."""
    for path in search_list():
        if not os.path.exists(path):
            continue
        kc = kc_load(path)
        for c in kc["certs"]:
            der = bytes.fromhex(c)
            info = cert_info(der)
            if info["sha1"] != spec.upper() or info["pub"] not in kc["keys"]:
                continue
            if not kc["unlocked"] or not kc["partition"]:
                die("%s: errSecInternalComponent" % spec)
            if not chains_to_root(info):
                die('Warning: unable to build chain to self-signed root for signer "%s"\n%s: errSecInternalComponent'
                    % (info["subject"].get("CN"), spec))
            return info, der
    die("%s: no identity found" % spec)


# ---- signatures ----------------------------------------------------------------
def sig_path(obj):
    return os.path.join(obj, "_CodeSignature", "stub.json")


def sig(obj):
    try:
        with open(sig_path(obj)) as f:
            return json.load(f)
    except FileNotFoundError:
        return None


def sig_hash(obj):
    with open(sig_path(obj), "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def nested(obj):
    return sorted(glob.glob(os.path.join(obj, "Frameworks", "*.framework")))


def bundle_id(obj):
    with open(os.path.join(obj, "Info.plist"), "rb") as f:
        return plistlib.load(f)["CFBundleIdentifier"]


def auto_dr(identifier, info):
    # What Xcode and codesign write: the common name, decomposed (NFD).
    return 'identifier "%s" and anchor apple generic and certificate leaf[subject.CN] = "%s"' % (
        identifier, unicodedata.normalize("NFD", info["subject"].get("CN", "")))


def parse_dr(expr):
    clauses = []
    for c in re.split(r"\s+and\s+", expr.strip()):
        c = c.strip()
        m = re.fullmatch(r'identifier "?([^"\s]+)"?', c) or re.fullmatch(
            r'certificate leaf\[subject\.(OU|CN)\] = "?([^"]*)"?', c)
        if c == "anchor apple generic":
            clauses.append(("anchor",))
        elif m and c.startswith("identifier"):
            clauses.append(("identifier", m.group(1)))
        elif m:
            clauses.append((m.group(1), m.group(2)))
        else:
            return None
    return clauses


def dr_ok(s):
    if s["adhoc"]:
        return True
    for c in parse_dr(s["dr"]):
        if c[0] == "identifier" and c[1] != s["identifier"]:
            return False
        if c[0] in ("OU", "CN") and s["leaf"]["subject"].get(c[0]) != c[1]:  # byte-exact, as Security does
            return False
    return True


def write_sig(obj, info, entitlements, identifier, dr):
    for f in nested(obj):
        if sig(f) is None:
            die("%s: code object is not signed at all\nIn subcomponent: %s" % (obj, f))
    s = {"identifier": identifier, "adhoc": info is None, "leaf": info and {k: info[k] for k in ("subject", "issuer", "sha1")},
         "entitlements": entitlements, "dr": dr, "seal": {os.path.basename(f): sig_hash(f) for f in nested(obj)}}
    os.makedirs(os.path.dirname(sig_path(obj)), exist_ok=True)
    with open(sig_path(obj), "w") as f:
        json.dump(s, f)


def verify(obj):
    s = sig(obj)
    if s is None:
        return ["%s: code object is not signed at all" % obj]
    errs = []
    for f in nested(obj):
        name = os.path.basename(f)
        if sig(f) is None or s["seal"].get(name) != sig_hash(f):
            errs.append("%s: a sealed resource is missing or invalid\nfile modified: %s" % (obj, f))
        errs += verify(f)
    if set(s["seal"]) - {os.path.basename(f) for f in nested(obj)}:
        errs.append("%s: a sealed resource is missing or invalid" % obj)
    if not dr_ok(s):
        errs.append("%s: valid on disk\n%s: does not satisfy its designated Requirement" % (obj, obj))
    return errs


def authorities(s):
    if s["adhoc"]:
        return []
    return [s["leaf"]["subject"].get("CN"), s["leaf"]["issuer"].get("CN"), E["STUB_ROOT_CN"]]


def ents_plist(ents):
    return plistlib.dumps(ents or {})


# ---- tools -----------------------------------------------------------------------
def codesign():
    flags, vals, paths, vcount = set(), {}, [], 0
    it, i = list(ARGS), 0
    takes = {"s": "sign", "r": "requirements", "i": "identifier", "o": "options"}
    while i < len(it):
        a = it[i]
        i += 1
        if a.startswith("--"):
            name, eq, val = a[2:].partition("=")
            if name in ("sign", "requirements", "identifier", "options", "entitlements", "keychain", "preserve-metadata"):
                if not eq:
                    if i >= len(it):
                        reject("--%s needs a value" % name)
                    val, i = it[i], i + 1
                vals[name] = val
            elif name in ("force", "deep", "strict", "display", "verify", "timestamp", "generate-entitlement-der"):
                flags.add(name)
            elif name == "verbose":
                vcount = max(vcount, int(val or 1))
            else:
                reject("unknown option --" + name)
        elif a.startswith("-") and len(a) > 1:
            j = 1
            while j < len(a):
                ch = a[j]
                j += 1
                if ch in takes:
                    arg = a[j:]
                    if not arg:
                        if i >= len(it):
                            reject("-%s needs a value" % ch)
                        arg, i = it[i], i + 1
                    vals[takes[ch]] = arg
                    break
                elif ch == "d":
                    flags.add("display")
                elif ch == "f":
                    flags.add("force")
                elif ch == "v":
                    vcount += 1
                else:
                    reject("unknown option -" + ch)
        else:
            paths.append(a)
    if len(paths) != 1:
        reject("one path expected")
    obj = paths[0].rstrip("/")
    if not os.path.exists(obj):
        die("%s: No such file or directory" % obj)
    if not (os.path.isdir(obj) and os.path.isfile(os.path.join(obj, "Info.plist"))):
        reject("not a bundle: " + obj)

    if "sign" in vals:
        if "display" in flags or "verify" in flags:
            reject("sign together with display/verify")
        old = sig(obj)
        if old and "force" not in flags:
            die("%s: is already signed" % obj)
        keep = set(filter(None, vals.get("preserve-metadata", "").split(",")))
        if keep - {"identifier", "entitlements", "requirements", "flags", "runtime", "launch-constraints"}:
            reject("unknown --preserve-metadata item")
        info = None if vals["sign"] == "-" else identity(vals["sign"])[0]
        if "entitlements" in vals:
            try:
                with open(vals["entitlements"], "rb") as f:
                    ents = plistlib.load(f)
            except Exception:
                die("%s: invalid entitlements file" % vals["entitlements"])
        else:
            ents = old["entitlements"] if old and "entitlements" in keep else None
        ident = vals.get("identifier") or (old["identifier"] if old and "identifier" in keep else bundle_id(obj))
        if "requirements" in vals:
            r = vals["requirements"]
            if not r.startswith("="):
                if not os.path.isfile(r):
                    die("%s: No such file or directory" % r)
                reject("requirement files are not modelled")
            m = re.fullmatch(r"=\s*designated\s*=>\s*(.+)", r, re.S)
            if not m or parse_dr(m.group(1)) is None:
                die("%s: invalid requirement syntax (or a form this stand-in does not model): %s" % (obj, r), 1)
            dr = m.group(1).strip()
        elif old and "requirements" in keep:
            dr = old["dr"]
        else:
            dr = None if info is None else auto_dr(ident, info)
        write_sig(obj, info, ents, ident, dr)
        print("%s: replacing existing signature" % obj if old else "%s: signed bundle" % obj, file=sys.stderr)
        return

    if "verify" in flags or ("display" not in flags and vcount):
        errs = verify(obj)
        if errs:
            die("\n".join(errs), 3 if "designated Requirement" in errs[-1] else 1)
        print("%s: valid on disk\n%s: satisfies its Designated Requirement" % (obj, obj), file=sys.stderr)
        return

    if "display" not in flags:
        reject("nothing to do")
    s = sig(obj)
    if s is None:
        die("%s: code object is not signed at all" % obj)
    print("Executable=%s/%s" % (obj, os.path.basename(obj).split(".")[0]), file=sys.stderr)
    if vcount:
        print("Identifier=%s\nFormat=bundle with Mach-O thin (arm64)" % s["identifier"], file=sys.stderr)
        if vcount >= 2:
            if s["adhoc"]:
                print("Signature=adhoc", file=sys.stderr)
            for a in authorities(s):
                print("Authority=%s" % a, file=sys.stderr)
        print("TeamIdentifier=%s" % ((s["leaf"] or {}).get("subject", {}).get("OU") or "not set"), file=sys.stderr)
    if "requirements" in vals:
        if vals["requirements"] != "-":
            reject("display requirements only to stdout")
        print("designated => %s" % (s["dr"] or 'cdhash H"00ad"'))
    if "entitlements" in vals:
        e = vals["entitlements"]
        if e not in (":-", "-"):
            reject("entitlements to a file, not stdout")
        if e == ":-":
            print("Warning: Specifying ':' in the path is deprecated and will not work in a future release", file=sys.stderr)
            sys.stdout.buffer.write(ents_plist(s["entitlements"]))
        else:
            print("[Dict]")
            for k, v in (s["entitlements"] or {}).items():
                print("\t[Key] %s\n\t[Value]\n\t\t[String] %s" % (k, v))


def plutil():
    args = ARGS
    if len(args) < 3 or args[0] != "-extract":
        reject("only -extract is expected")
    keypath, fmt, rest = args[1], args[2], list(args[3:])
    if fmt not in ("xml1", "binary1", "json", "swift", "objc", "raw"):
        reject("bad format " + fmt)
    out, files = None, []
    while rest:
        a = rest.pop(0)
        if a == "-o":
            out = rest.pop(0)
        elif a == "-expect":
            rest.pop(0)
        elif a.startswith("-") and a != "-":
            reject("unknown flag " + a)
        else:
            files.append(a)
    if len(files) != 1:
        reject("one input file expected")
    if out != "-":
        reject("extract without -o - would rewrite the input")
    name = "<stdin>" if files[0] == "-" else files[0]
    try:
        data = sys.stdin.buffer.read() if files[0] == "-" else open(files[0], "rb").read()
    except FileNotFoundError:
        die("%s: file does not exist or is not readable" % name)
    try:
        v = plistlib.loads(data)
    except Exception:
        die("%s: Property List error: Cannot parse a NULL or zero-length data" % name)
    for part in keypath.split("."):
        if not isinstance(v, dict) or part not in v:
            die("%s: Could not extract value, error: No value at that key path or invalid key path: %s" % (name, keypath))
        v = v[part]
    if fmt != "raw":
        reject("only raw is modelled")
    if isinstance(v, (dict, list)):
        die("%s: Could not extract value: not a scalar" % name)
    print(str(v).lower() if isinstance(v, bool) else v)


def security():
    if not ARGS:
        reject("no command")
    cmd, a = ARGS[0], list(ARGS[1:])

    def opt(flag, has_value=True):
        if flag in a:
            i = a.index(flag)
            v = a[i + 1] if has_value else True
            del a[i:i + (2 if has_value else 1)]
            return v
        return None

    if cmd == "create-keychain":
        pw = opt("-p")
        if pw is None or len(a) != 1:
            reject("create-keychain -p PASSWORD KEYCHAIN")
        if os.path.exists(a[0]):
            die("security: SecKeychainCreate %s: A keychain with the same name already exists." % a[0], 48)
        kc_save(a[0], {"password": pw, "unlocked": True, "partition": False, "certs": [], "keys": []})
    elif cmd == "unlock-keychain":
        pw = opt("-p")
        if pw is None or len(a) != 1:
            reject("unlock-keychain -p PASSWORD KEYCHAIN")
        kc = kc_load(a[0])
        if kc["password"] != pw:
            die("security: SecKeychainUnlock %s: The user name or passphrase you entered is not correct." % a[0], 51)
        kc["unlocked"] = True
        kc_save(a[0], kc)
    elif cmd == "import":
        path = a.pop(0) if a and not a[0].startswith("-") else reject("import FILE first")
        kcp = opt("-k")
        while opt("-T"):
            pass
        opt("-A", False)
        if a or kcp is None:
            reject("import FILE -k KEYCHAIN [-T APP]... expected")
        kc = kc_load(kcp)
        if not kc["unlocked"]:
            die("security: SecKeychainItemImport: User interaction is not allowed.")
        with open(path, "rb") as f:
            data = f.read()
        der = to_der(data)
        if der:
            kc["certs"].append(der.hex())
            print("1 certificate imported.")
        else:
            p = ossl("pkey", "-pubout", data=data)
            if p.returncode != 0:
                die("security: SecKeychainItemImport: Unknown format in import.")
            kc["keys"].append(p.stdout.decode())
            print("1 key imported.")
        kc_save(kcp, kc)
    elif cmd == "set-key-partition-list":
        parts, pw = opt("-S"), opt("-k")
        opt("-s", False)
        if parts is None or pw is None or len(a) != 1:
            reject("set-key-partition-list -S LIST -s -k PASSWORD KEYCHAIN")
        kc = kc_load(a[0])
        if kc["password"] != pw:
            die("security: SecItemCopyMatching: The user name or passphrase you entered is not correct.", 51)
        if "apple-tool:" not in parts.split(",") or "apple:" not in parts.split(","):
            die("partition list lacks apple-tool:/apple:")
        kc["partition"] = True
        kc_save(a[0], kc)
    elif cmd == "list-keychains":
        dom = opt("-d")
        if dom not in (None, "user"):
            reject("only the user domain is modelled")
        if "-s" in a:
            i = a.index("-s")
            new, a = a[i + 1:], a[:i]
            if a:
                reject("stray arguments")
            with open(search_file(), "w") as f:
                json.dump(new, f)
        elif a:
            reject("stray arguments")
        else:
            for k in search_list():
                print('    "%s"' % k)
    elif cmd == "delete-keychain":
        if not a:
            reject("delete-keychain KEYCHAIN")
        for k in a:
            if not os.path.exists(k):
                die("security: SecKeychainDelete: The specified keychain could not be found.", 50)
            os.remove(k)
            lst = [x for x in search_list() if x != k]
            with open(search_file(), "w") as f:
                json.dump(lst, f)
        record("security delete-keychain")
    elif cmd == "cms":
        dec, inp = opt("-D", False), opt("-i")
        if not dec or inp is None or a:
            reject("cms -D -i FILE")
        try:
            data = open(inp, "rb").read()
        except FileNotFoundError:
            die("security: cms: unable to open \"%s\"" % inp)
        if not data.startswith(b"STUBCMS\n"):
            die("security: failed to decode message")
        sys.stdout.buffer.write(data[len(b"STUBCMS\n"):])
    else:
        reject("command %s is not modelled" % cmd)


def xcodebuild():
    if ARGS == ["-version"]:
        record("xcodebuild -version")
        print("Xcode 26.0.1\nBuild version 17A400")
        return
    mode, o, settings = None, {}, {}
    it = list(ARGS)
    while it:
        a = it.pop(0)
        if a == "archive":
            mode = "archive"
        elif a == "-exportArchive":
            mode = "export"
        elif a in ("-quiet", "-allowProvisioningUpdates"):
            o[a] = True
        elif a in ("-workspace", "-scheme", "-configuration", "-destination", "-archivePath", "-exportPath",
                   "-exportOptionsPlist", "-authenticationKeyPath", "-authenticationKeyID", "-authenticationKeyIssuerID"):
            if not it:
                reject(a + " needs a value")
            o[a] = it.pop(0)
        elif re.fullmatch(r"[A-Z_][A-Z0-9_]*=.*", a):
            k, _, v = a.partition("=")
            settings[k] = v
        else:
            reject("unexpected argument " + a)
    if mode is None or "-archivePath" not in o:
        reject("archive or -exportArchive with -archivePath expected")
    if "-authenticationKeyPath" in o and not os.path.isfile(o["-authenticationKeyPath"]):
        die("error: authentication key file not found: %s" % o["-authenticationKeyPath"], 70)
    record("xcodebuild %s %s" % (mode, " ".join(ARGS)))
    arch = o["-archivePath"]
    if mode == "archive":
        if (o.get("-workspace"), o.get("-scheme"), o.get("-configuration")) != ("ios/Runner.xcworkspace", "Runner", "Release"):
            reject("archive of the wrong target")
        xc = E.get("XCODE_XCCONFIG_FILE")
        unsigned = settings.get("CODE_SIGNING_ALLOWED") == "NO"
        if xc and os.path.isfile(xc):
            unsigned |= bool(re.search(r"^\s*CODE_SIGNING_ALLOWED\s*=\s*NO\s*$", open(xc).read(), re.M))
        if not unsigned:
            die('error: No profiles for \'com.esd.sis\' were found: Xcode couldn\'t find any iOS App Development '
                'provisioning profiles matching \'com.esd.sis\'. (the team has no registered device)', 65)
        app = os.path.join(arch, "Products/Applications/Runner.app")
        # The frameworks carry the linker's ad-hoc signature (every arm64
        # binary does); the app is unsigned.
        for sub, ident in (("Frameworks/Flutter.framework", "io.flutter.flutter"),
                           ("Frameworks/App.framework", "io.flutter.flutter.app"),
                           ("Frameworks/objective_c.framework", "io.flutter.flutter.native-assets.objective-c"),
                           ("", "com.esd.sis")):
            d = os.path.join(app, sub)
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, "Info.plist"), "wb") as f:
                plistlib.dump({"CFBundleIdentifier": ident}, f)
            if sub:
                write_sig(d, None, None, ident, None)
        return
    # export
    if not os.path.isdir(arch):
        die("error: archive not found at path '%s'" % arch, 70)
    with open(o["-exportOptionsPlist"], "rb") as f:
        raw = f.read()
    with open(E["STUB_EXPORT_OPTIONS"], "wb") as f:
        f.write(raw)
    try:
        opts = plistlib.loads(raw)
    except Exception:
        die("error: exportOptionsPlist error: the file couldn't be opened because it isn't in the correct format", 70)
    if E.get("STUB_EXPORT_FAIL"):
        die("error: exportArchive: the stand-in was told to fail", 70)
    if opts.get("method") not in ("app-store-connect", "app-store"):
        die("error: exportArchive: method is not an App Store Connect distribution", 70)
    if opts.get("signingStyle") != "manual":
        die("error: exportArchive: automatic signing needs a signed-in account (no -allowProvisioningUpdates here)", 70)
    cert = opts.get("signingCertificate", "")
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", cert):
        die('error: exportArchive: No signing certificate "%s" found' % cert, 70)
    info, der = identity(cert)
    if opts.get("teamID") != info["subject"].get("OU"):
        die("error: exportArchive: teamID %s is not the certificate's team" % opts.get("teamID"), 70)
    uuid = (opts.get("provisioningProfiles") or {}).get("com.esd.sis")
    prof = None
    # Xcode 16 and later read profiles from UserData only, not MobileDevice.
    for d in ("Library/Developer/Xcode/UserData/Provisioning Profiles",):
        p = os.path.join(E["HOME"], d, "%s.mobileprovision" % uuid)
        if uuid and os.path.isfile(p):
            with open(p, "rb") as f:
                prof = plistlib.loads(f.read()[len(b"STUBCMS\n"):])
            break
    if prof is None:
        die('error: exportArchive: No profiles for \'com.esd.sis\' were found (provisioningProfiles %r)' % uuid, 70)
    if der not in prof.get("DeveloperCertificates", []):
        die("error: exportArchive: Provisioning profile doesn't include signing certificate", 70)
    src = os.path.join(arch, "Products/Applications/Runner.app")
    exp = o["-exportPath"]
    stage = os.path.join(exp, ".stage")
    import shutil
    shutil.copytree(src, os.path.join(stage, "Payload/Runner.app"))
    app = os.path.join(stage, "Payload/Runner.app")
    for f in nested(app):
        write_sig(f, info, None, bundle_id(f), auto_dr(bundle_id(f), info))
    old = sig(src)
    ents = dict(old["entitlements"] or {}) if old else {}
    for k, v in prof["Entitlements"].items():
        if k in ents or k in ("application-identifier", "com.apple.developer.team-identifier"):
            ents[k] = v
    write_sig(app, info, ents, "com.esd.sis", auto_dr("com.esd.sis", info))
    with zipfile.ZipFile(os.path.join(exp, "sis.ipa"), "w") as z:  # named after the product, not the scheme
        for r, _, fs in os.walk(stage):
            for f in fs:
                full = os.path.join(r, f)
                z.write(full, os.path.relpath(full, stage))
    shutil.rmtree(stage)
    with open(os.path.join(exp, "ExportOptions.plist"), "wb") as f:
        f.write(raw)


def xcrun():
    if not ARGS or ARGS[0] != "altool":
        reject("only altool is expected")
    it, o, action = list(ARGS[1:]), {}, None
    while it:
        a = it.pop(0)
        if a in ("--upload-app", "--validate-app"):
            if action:
                reject("two actions")
            action = a[2:-4]
        elif a in ("--type", "-t", "--file", "-f", "--apiKey", "--apiIssuer"):
            if not it:
                reject(a + " needs a value")
            o[{"-t": "--type", "-f": "--file"}.get(a, a)] = it.pop(0)
        else:
            reject("unexpected argument " + a)
    if not action or o.get("--type") != "ios":
        reject("not an iOS upload/validation")
    ipa = o.get("--file", "")
    if not os.path.isfile(ipa):
        die("*** Error: file not found: %s" % ipa)
    kid = o.get("--apiKey") or reject("no --apiKey")
    o.get("--apiIssuer") or reject("no --apiIssuer")
    dirs = ["./private_keys"] + [os.path.join(E["HOME"], d) for d in ("private_keys", ".private_keys", ".appstoreconnect/private_keys")]
    if E.get("API_PRIVATE_KEYS_DIR"):
        dirs.append(E["API_PRIVATE_KEYS_DIR"])
    if not any(os.path.isfile(os.path.join(d, "AuthKey_%s.p8" % kid)) for d in dirs):
        die("*** Error: Could not find private key AuthKey_%s.p8" % kid)
    import shutil
    import tempfile
    t = tempfile.mkdtemp()
    try:
        with zipfile.ZipFile(ipa) as z:
            z.extractall(t)
        apps = glob.glob(os.path.join(t, "Payload", "*.app"))
        if len(apps) != 1:
            die("*** Error: Validation failed (409) Invalid bundle. No app in Payload.")
        problems = []
        for obj in [apps[0]] + nested(apps[0]):
            s = sig(obj)
            if s is None or s["adhoc"] or not authorities(s)[0].startswith("Apple Distribution: "):
                problems.append("%s is not signed with an Apple Distribution certificate" % os.path.basename(obj))
        problems += verify(apps[0])
        if problems:
            die("*** Error: Validation failed (409) Invalid Signature. %s" % "; ".join(problems))
    finally:
        shutil.rmtree(t)
    record("altool %s %s" % (action, ipa))
    print("No errors %s archive at '%s'." % ("validating" if action == "validate" else "uploading", ipa))


def curl():
    it, out, url, fl = list(ARGS), None, None, set()
    while it:
        a = it.pop(0)
        if a == "-o":
            out = it.pop(0) if it else reject("-o needs a file")
        elif re.fullmatch(r"-[sSfL]+", a):
            fl |= set(a[1:])
        elif a.startswith("-"):
            reject("unexpected option " + a)
        else:
            if url:
                reject("one URL expected")
            url = a
    if not url or not out:
        reject("curl -sSf URL -o FILE expected")
    urls = json.loads(E["STUB_URLS"])
    if url not in urls:
        if "f" in fl:
            die("curl: (22) The requested URL returned error: 404", 22)
        open(out, "wb").write(b"<html>404</html>")
        return
    record("curl %s" % url)
    with open(urls[url], "rb") as s, open(out, "wb") as d:
        d.write(s.read())


# LibreSSL 3.3 (macOS /usr/bin/openssl) lacks these; a step using one breaks there.
OPENSSL3_ONLY = {"-noenc", "-copy_extensions", "-legacy", "-provider", "-provider-path", "-propquery",
                 "-not_before", "-not_after", "-ext", "-CA", "-CAkey"}


def openssl():
    bad = [a for a in ARGS if a in OPENSSL3_ONLY]
    if bad:
        reject("LibreSSL has no %s" % " ".join(bad))
    os.execv(OPENSSL, [OPENSSL, *ARGS])


def asc_signing():
    """tool/asc_signing.py stood in for: App Store Connect's side of it."""
    kid, d = E.get("KEY_ID"), E.get("API_PRIVATE_KEYS_DIR")
    if not (kid and d and os.path.isfile(os.path.join(d, "AuthKey_%s.p8" % kid)) and E.get("ISSUER_ID")):
        die("asc_signing: no App Store Connect key (API_PRIVATE_KEYS_DIR, KEY_ID, ISSUER_ID)")
    team = E["STUB_TEAM"]
    if ARGS[:1] == ["create"] and len(ARGS) == 5:
        csr, bundle, name, out = ARGS[1:]
        if ossl("req", "-in", csr, "-noout", "-verify").returncode != 0:
            die("asc_signing: POST /v1/certificates: 409 ENTITY_ERROR (not a CSR: %s)" % csr)
        if bundle != "com.esd.sis":
            die("asc_signing: no bundle id %s" % bundle)
        if not os.path.isdir(out):
            die("asc_signing: %s is not a directory" % out)
        record("asc create %s %s" % (bundle, name))
        org = "Şirket Adı Çağ"
        cn = "%s: %s (%s)" % (E.get("STUB_CERT_KIND", "Apple Distribution"), org, team)
        ca = E["STUB_CA"]
        with open(os.path.join(ca, "inter.cer"), "rb") as f:
            inter_pem = ossl("x509", "-inform", "der", data=f.read()).stdout
        with open(os.path.join(ca, "inter.pem"), "wb") as f:
            f.write(inter_pem)
        p = ossl("req", "-x509", "-in", csr, "-CA", os.path.join(ca, "inter.pem"), "-CAkey", os.path.join(ca, "inter.key"),
                 "-utf8", "-days", "1", "-subj", "/CN=%s/OU=%s/O=%s/C=TR" % (cn, team, org),
                 "-addext", "authorityInfoAccess=caIssuers;URI:http://certs.apple.com/wwdrg3.der", "-outform", "der")
        if p.returncode != 0 or not p.stdout:
            die("asc_signing stand-in: could not issue: %s" % p.stderr.decode())
        with open(os.path.join(out, "cert.cer"), "wb") as f:
            f.write(p.stdout)
        print("SIGNING_CERTIFICATE_ID=CERT-1", flush=True)
        if E.get("STUB_ASC_FAIL") == "profile":
            die("asc_signing: POST /v1/profiles: 409 ENTITY_ERROR")
        import uuid
        prof = {"Name": name, "UUID": str(uuid.uuid4()).upper(), "TeamIdentifier": [team], "DeveloperCertificates": [p.stdout],
                "Entitlements": {"application-identifier": team + ".com.esd.sis", "com.apple.developer.team-identifier": team,
                                 "aps-environment": E.get("STUB_PROFILE_APS", "production"), "get-task-allow": False}}
        with open(os.path.join(out, "profile.mobileprovision"), "wb") as f:
            f.write(b"STUBCMS\n" + plistlib.dumps(prof))
        print("SIGNING_PROFILE_ID=PROF-1")
    elif ARGS[:1] == ["delete"] and len(ARGS) == 3:
        record("asc delete %s %s" % tuple(ARGS[1:]))
    else:
        reject("usage: create CSR BUNDLE_ID PROFILE_NAME OUT_DIR | delete CERT_ID PROFILE_ID")


{"codesign": codesign, "asc_signing.py": asc_signing, "plutil": plutil, "security": security, "xcodebuild": xcodebuild,
 "xcrun": xcrun, "curl": curl, "openssl": openssl}[TOOL]()
