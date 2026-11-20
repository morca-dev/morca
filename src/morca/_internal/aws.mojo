"""`morca aws`: a project's morca on AWS, with the `aws` and `docker` commands
its user already has (`aws login`, or `AWS_PROFILE` for a named profile).

    morca aws up --email you@example.com [--stack orca] [--hostname H]
                [--console-hostname H] [--budget 100] [--zone us-east-2a]
                [--public-data true|false] [--env KEY=VALUE ...]
    morca aws push [--tag T]                     # the project's image, to ECR
    morca aws register [--tag T] [--config F|--no-config] [register flags]
                      <pipeline> [...]
    morca aws app <name> [--host H] [--port 8080] [--tag T]
    morca aws status
    morca aws replace-control [--plan] [--wait] [--keep-old 24h] [--smoke P=KEY]
                             [--env KEY=VALUE ...] | --resume | --rollback
    morca aws down --yes

`up` creates or updates the stack from the template morca carries
(deploy/aws/morca.yaml, in `morca._internal.aws_assets`); the first time it needs
`--email`, for the Budgets alert, and makes the database's password. `push`
builds the project's image from a staged copy of `pixi.toml`, `pixi.lock`,
`bin/`, `pipelines/` and `src/`, with the project's `Dockerfile.morca` or
else the template (deploy/project.Dockerfile, which builds FROM
`ghcr.io/morca-dev/morca-runtime:<the morca-mojo version in pixi.lock>`),
for arm64, tagged with the commit (or `--tag`) and `latest`, and pushes it
to the stack's repository.
`register` and `app` run on the control instance through SSM: `register`
moves the scheduler and the UI to the image (`orca-refresh`) and registers
each pipeline, `/opt/morca/pipelines/<pipeline>`, with the flags given, as
`morca register` takes them, and the project's `morca.toml` (or `--config`'s
file; `morca._internal.config`), which it checks and sends whole with its git commit; `app` runs the image's `/opt/morca/bin/<name>`
beside the UI, at `https://<host>` (for `console`, the stack's
`ConsoleHostname`). `--env KEY=VALUE` (repeated) sets the control
instance's settings beyond the template's (`ControlEnv`, all of them at
once; never a secret). An update changes no running control instance: its
boot script is the stack's `ControlBoot`, which a new one runs, and each
slot's AMI is pinned to the one its instance has. `replace-control`
(`morca._internal.aws_replace`) boots a new control instance from the template, with
the old one's database, and moves the Elastic IP to it. `down` deletes the
stack, which fails while its buckets hold objects.

Files go to `build/morca-aws/`. `--stack` (default `orca`, the name of the stack made before the rename) and `--region`
(default `AWS_REGION`, else the `aws` command's own) go anywhere.
"""

from std.base64 import b64encode
from std.ffi import c_int, external_call
from std.os import getenv
from std.os.path import exists
from std.time import sleep

from json import loads

from morca._internal.aws_assets import PROJECT_DOCKERFILE, STACK_TEMPLATE
from morca._internal.config import ProjectConfig, refuse_orca_toml
from morca._internal.json import quote
from morca._internal.proc import capture

comptime _DIR = "build/morca-aws"
comptime AWS_USAGE = """usage:
  morca aws up --email ADDR [--hostname H] [--console-hostname H] [--budget N]
              [--zone AZ] [--public-data true|false] [--env KEY=VALUE ...]
  morca aws push [--tag T]
  morca aws register [--tag T] [--config F|--no-config] [register flags]
                    <pipeline> [...]
  morca aws app <name> [--host H] [--port 8080] [--tag T]
  morca aws status
  morca aws replace-control [--plan] [--wait] [--keep-old 24h] [--smoke P=KEY]
                           [--env KEY=VALUE ...] | --resume | --rollback
  morca aws down --yes
  (each takes --stack NAME, default orca, and --region R)"""

comptime _VALUED = [
    "--stack",
    "--region",
    "--tag",
    "--email",
    "--hostname",
    "--console-hostname",
    "--budget",
    "--zone",
    "--public-data",
    "--host",
    "--port",
    "--env",
    "--keep-old",
    "--smoke",
]
"""`morca aws`'s own options with a value; any other is `register`'s."""
comptime _REGISTER_VALUED = [
    "--head-type",
    "--worker-type",
    "--workers",
    "--worker-procs",
    "--secret",
    "--placement",
    "--max-runs",
    "--cpus",
    "--memory-gb",
]


def _q(s: String) -> String:
    """`s` as one shell word."""
    return String("'", s.replace("'", "'\\''"), "'")


def env_problem(kv: String) -> String:
    """Why `kv` can't be one of the control instance's settings
    (`--env KEY=VALUE`, the stack's `ControlEnv`), or empty if it can."""
    var eq = kv.find("=").or_else(-1)
    if eq <= 0:
        return String("is KEY=VALUE, not ", kv)
    var key = String(kv[byte=:eq])
    var i = 0
    for b in key.as_bytes():
        var c = Int(b)
        var ok = (c >= ord("A") and c <= ord("Z")) or c == ord("_")
        if i > 0 and c >= ord("0") and c <= ord("9"):
            ok = True
        if not ok:
            return String("has a key of A-Z, 0-9 and _: ", key)
        i += 1
    if "'" in kv or ";" in kv or "\n" in kv:
        return String("can't hold ', ; or a newline: ", key)
    for word in ["PASSWORD", "SECRET", "TOKEN", "DATABASE_URL"]:
        if word in key:
            return String(
                "is for settings, not secrets (",
                key,
                "): the stack's parameters are plain text",
            )
    return ""


def _system(cmd: String) raises -> Int:
    """Runs `cmd` through the shell, its output to ours; its exit code."""
    var c = List[UInt8](cmd.as_bytes())
    c.append(0)
    var s = Int(external_call["system", c_int](c.unsafe_ptr()))
    if s < 0:
        raise Error("morca aws: can't run ", cmd)
    return (s >> 8) & 0xFF if s & 0x7F == 0 else 128 + (s & 0x7F)


def _run(cmd: String) raises:
    print("+", cmd)
    var code = _system(cmd)
    if code != 0:
        raise Error("morca aws: exit ", code, ": ", cmd)


def _out(cmd: String) raises -> String:
    """`cmd`'s standard output, stripped; raises if it fails."""
    var got = capture(["sh", "-c", cmd])
    if got[0] != 0:
        raise Error("morca aws: exit ", got[0], ": ", cmd)
    return String(got[1].strip())


struct _Opts(Movable):
    var stack: String
    var region: String
    var tag: String
    var email: String
    var hostname: String
    var console_hostname: String
    var budget: String
    var zone: String
    var public_data: String
    """`true` lets anyone read the lake's bucket unsigned; empty keeps the
    stack's setting (private for a new one)."""
    var host: String
    var port: String
    var yes: Bool
    var env: List[String]
    """`--env KEY=VALUE`, in order: the stack's `ControlEnv`."""
    var keep_old: String
    var smoke: String
    var plan: Bool
    var wait: Bool
    var rollback: Bool
    var resume: Bool
    var rest: List[String]
    """The arguments that aren't `morca aws`'s own options, in order."""

    def __init__(out self, args: List[String], start: Int) raises:
        self.stack = String(
            "orca"
        )  # the stack made before the rename keeps its name
        self.region = getenv("AWS_REGION")
        self.tag = String()
        self.email = String()
        self.hostname = String()
        self.console_hostname = String()
        self.budget = String()
        self.zone = String()
        self.public_data = String()
        self.host = String()
        self.port = String("8080")
        self.yes = False
        self.env = List[String]()
        self.keep_old = String()
        self.smoke = String()
        self.plan = False
        self.wait = False
        self.rollback = False
        self.resume = False
        self.rest = List[String]()
        var i = start
        while i < len(args):
            var a = args[i]
            if a == "--yes" or a == "--plan" or a == "--wait":
                if a == "--yes":
                    self.yes = True
                elif a == "--plan":
                    self.plan = True
                else:
                    self.wait = True
                i += 1
                continue
            if a == "--rollback" or a == "--resume":
                if a == "--rollback":
                    self.rollback = True
                else:
                    self.resume = True
                i += 1
                continue
            var ours = False
            for v in materialize[_VALUED]():
                if a == v:
                    ours = True
            if not ours:
                self.rest.append(a)
                i += 1
                continue
            if i + 1 >= len(args):
                raise Error("morca aws: ", a, " needs a value")
            var v = args[i + 1]
            if a == "--stack":
                self.stack = v
            elif a == "--region":
                self.region = v
            elif a == "--tag":
                self.tag = v
            elif a == "--email":
                self.email = v
            elif a == "--hostname":
                self.hostname = v
            elif a == "--console-hostname":
                self.console_hostname = v
            elif a == "--budget":
                self.budget = v
            elif a == "--zone":
                self.zone = v
            elif a == "--public-data":
                if v != "true" and v != "false":
                    raise Error("morca aws: --public-data is true or false")
                self.public_data = v
            elif a == "--host":
                self.host = v
            elif a == "--env":
                var why = env_problem(v)
                if why:
                    raise Error("morca aws: --env ", why)
                self.env.append(v)
            elif a == "--keep-old":
                self.keep_old = v
            elif a == "--smoke":
                self.smoke = v
            else:
                self.port = v
            i += 2

    def aws(self, args: String) -> String:
        """An `aws` command line, in the region given."""
        var out = String("aws ")
        if self.region:
            out.write("--region ", _q(self.region), " ")
        out.write(args)
        return out^


def _outputs(o: _Opts) raises -> Dict[String, String]:
    """The stack's outputs, by key."""
    var text = _out(
        o.aws(
            String(
                "cloudformation describe-stacks --stack-name ",
                _q(o.stack),
                " --query 'Stacks[0].Outputs' --output json",
            )
        )
    )
    var out = Dict[String, String]()
    for item in loads(text).array_items():
        out[item["OutputKey"].string_value()] = item[
            "OutputValue"
        ].string_value()
    return out^


def _output(outs: Dict[String, String], key: String) raises -> String:
    var v = outs.get(key, "")
    if not v:
        raise Error("morca aws: the stack has no output ", key)
    return v^


def _stack_exists(o: _Opts) raises -> Bool:
    return (
        _system(
            String(
                o.aws(
                    String(
                        "cloudformation describe-stacks --stack-name ",
                        _q(o.stack),
                    )
                ),
                " > /dev/null 2>&1",
            )
        )
        == 0
    )


def _write(path: String, text: StaticString) raises:
    _run(String("mkdir -p ", _q(_DIR)))
    with open(path, "w") as f:
        f.write(text)


def _git(args: String) -> String:
    try:
        return _out(String("git ", args, " 2> /dev/null"))
    except:
        return ""


def lock_morca_version(lock: String) -> String:
    """The morca-mojo version a project's pixi.lock resolved, which names the
    runtime image its Dockerfile builds FROM (`morca-runtime:<version>`):
    a source package's record (`- conda_source: morca-mojo[...] @ git+...`,
    then its `version:` line) or a channel package's file name
    (`- conda: .../morca-mojo-0.24.0-<build>.conda`); "" if it has neither."""
    var in_morca = False
    for raw in lock.split("\n"):
        var line = String(raw)
        if line.startswith("- "):
            in_morca = line.startswith("- conda_source: morca-mojo[")
            var name = "/morca-mojo-"
            var at = line.find(name).or_else(-1)
            if line.startswith("- conda: ") and at >= 0:
                var rest = String(line[byte = at + name.byte_length() :])
                var dash = rest.find("-").or_else(-1)
                if dash > 0:
                    return String(rest[byte=:dash])
            continue
        if in_morca:
            var t = String(raw.strip())
            if t.startswith("version: "):
                return String(t[byte=9:].strip())
    return ""


def _tag(o: _Opts) -> String:
    """The image tag: `--tag`, else the commit's first 12, else latest."""
    if o.tag:
        return o.tag
    var commit = _git("rev-parse HEAD")
    if commit.byte_length() >= 12:
        return String(commit[byte=:12])
    return "latest"


def _up(o: _Opts) raises -> Int:
    var params = List[String]()
    if not _stack_exists(o):
        if not o.email:
            print(
                "morca aws up: a new stack needs --email, for its budget alert"
            )
            return 2
        # The database's password, made once; updates keep it.
        params.append(
            String(
                "DbPassword=",
                _out("od -An -N18 -tx1 /dev/urandom | tr -d ' \\n'"),
            )
        )
    if o.email:
        params.append(String("BudgetEmail=", o.email))
    if o.hostname:
        params.append(String("Hostname=", o.hostname))
    if o.console_hostname:
        params.append(String("ConsoleHostname=", o.console_hostname))
    if o.budget:
        params.append(String("BudgetDollars=", o.budget))
    if o.zone:
        params.append(String("AvailabilityZone=", o.zone))
    if o.public_data:
        params.append(String("PublicData=", o.public_data))
    if len(o.env) > 0:
        params.append(control_env(o))
    if _stack_exists(o):
        var outs = _outputs(o)
        if "ActiveControl" not in outs and not o.yes:
            print(
                "morca aws up: the stack",
                o.stack,
                (
                    "predates the control instance's slots: this update"
                    " moves its boot script out of its user data, so"
                    " CloudFormation stops and starts it once. Pause its"
                    " pipelines and run it again with --yes, or let morca aws"
                    " replace-control make the update with a new instance."
                ),
            )
            return 2
        for p in slot_pins(o, outs):
            params.append(p)
    # The command line holds the password: run it without echoing it.
    deploy(o, params, False)
    return _status(o)


def control_env(o: _Opts) -> String:
    """The `ControlEnv` parameter `--env` gives."""
    var out = String("ControlEnv=")
    for i in range(len(o.env)):
        out.write("" if i == 0 else ";", o.env[i])
    return out^


def deploy(o: _Opts, params: List[String], show: Bool) raises:
    """`cloudformation deploy` of the template morca carries with `params`
    (the others keep their values), printing them if `show`."""
    var template = String(_DIR, "/morca.yaml")
    _write(template, STACK_TEMPLATE)
    var cmd = o.aws(
        String(
            "cloudformation deploy --stack-name ",
            _q(o.stack),
            " --template-file ",
            _q(template),
            " --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset",
        )
    )
    var shown = String("+ aws cloudformation deploy --stack-name ", o.stack)
    if len(params) > 0:
        cmd.write(" --parameter-overrides")
        for p in params:
            cmd.write(" ", _q(p))
        if show:
            shown.write(" --parameter-overrides")
            for p in params:
                shown.write(" ", _q(p))
        else:
            shown.write(" ...")
    print(shown)
    var code = _system(cmd)
    if code != 0:
        raise Error("morca aws: cloudformation deploy exited ", code)


def image_of(o: _Opts, instance: String) raises -> String:
    """The AMI `instance` was started from."""
    return _out(
        o.aws(
            String(
                "ec2 describe-instances --instance-ids ",
                _q(instance),
                " --query 'Reservations[0].Instances[0].ImageId' --output text",
            )
        )
    )


def slot_pins(o: _Opts, outs: Dict[String, String]) raises -> List[String]:
    """`BlueAmi=` and `GreenAmi=` the images the slots' instances have, so
    that an update, whose `Ami` resolves again, replaces neither."""
    var out = List[String]()
    var blue = outs.get("BlueInstance", "")
    if not blue and "ActiveControl" not in outs:
        # A stack from before the slots: its instance is blue's.
        blue = outs.get("ControlInstance", "")
    if blue:
        out.append(String("BlueAmi=", image_of(o, blue)))
    var green = outs.get("GreenInstance", "")
    if green:
        out.append(String("GreenAmi=", image_of(o, green)))
    return out^


def _status(o: _Opts) raises -> Int:
    var outs = _outputs(o)
    for e in outs.items():
        print(e.key, e.value, sep="\t")
    return 0


def _push(o: _Opts) raises -> Int:
    if not exists("pixi.toml") or not exists("bin/scheduler.mojo"):
        print(
            "morca aws push: run it in the project, which needs pixi.toml and"
            " bin/scheduler.mojo"
        )
        return 2
    var manifest: String
    with open("pixi.toml", "r") as f:
        manifest = f.read()
    if '"linux-aarch64"' not in manifest:
        print(
            "morca aws push: the image is linux-aarch64, which pixi.toml's"
            " platforms don't list; add it with\n    pixi workspace platform"
            " add linux-aarch64"
        )
        return 2
    var repo = _output(_outputs(o), "Repository")
    var registry = String(repo[byte = : repo.find("/").or_else(-1)])
    var tag = _tag(o)
    var ctx = String(_DIR, "/context")
    _run(
        String(
            "rm -rf ",
            _q(ctx),
            " && mkdir -p ",
            _q(ctx),
            " && cp pixi.toml pixi.lock ",
            _q(ctx),
            " && for d in bin pipelines src; do [ ! -d $d ] || cp -R $d ",
            _q(ctx),
            "/; done",
        )
    )
    # The template builds FROM the runtime image of the morca the project
    # pins (deploy/project.Dockerfile); a Dockerfile.morca may use it too.
    var lock: String
    with open("pixi.lock", "r") as f:
        lock = f.read()
    var morca_version = lock_morca_version(lock)
    var dockerfile = String("Dockerfile.morca")
    if not exists(dockerfile):
        if not morca_version:
            print(
                "morca aws push: pixi.lock has no morca-mojo, whose version"
                " names the image the project's builds on"
                " (ghcr.io/morca-dev/morca-runtime:<version>); run pixi"
                " install first"
            )
            return 2
        dockerfile = String(_DIR, "/Dockerfile")
        _write(dockerfile, PROJECT_DOCKERFILE)
    var version_arg = String("")
    if morca_version:
        version_arg = String(" --build-arg MORCA_VERSION=", _q(morca_version))
    var image = String(repo, ":", tag)
    _run(
        String(
            "docker build --platform linux/arm64 -f ",
            _q(dockerfile),
            version_arg,
            " --build-arg MORCA_SOURCE=",
            _q(_git("remote get-url origin")),
            " --build-arg MORCA_COMMIT=",
            _q(_git("rev-parse HEAD")),
            " -t ",
            _q(image),
            " -t ",
            _q(String(repo, ":latest")),
            " ",
            _q(ctx),
        )
    )
    _run(
        String(
            o.aws("ecr get-login-password"),
            " | docker login --username AWS --password-stdin ",
            _q(registry),
        )
    )
    _run(String("docker push ", _q(image)))
    _run(String("docker push ", _q(String(repo, ":latest"))))
    print("pushed", image)
    return 0


def _ssm(o: _Opts, instance: String, commands: List[String]) raises -> Int:
    """Runs `commands` on `instance` through SSM, prints what they wrote,
    and returns 0 if they succeeded."""
    for c in commands:
        print("+ on the control instance:", c)
    return ssm_run(o, instance, commands)[0]


def ssm_run(
    o: _Opts, instance: String, commands: List[String]
) raises -> Tuple[Int, String]:
    """Runs `commands` on `instance` through SSM and prints what they wrote;
    0 and their output if they succeeded, else 3 and it."""
    var params = String('{"commands": [')
    for i in range(len(commands)):
        params.write("" if i == 0 else ", ", quote(commands[i]))
    params.write("]}")
    var id = _out(
        o.aws(
            String(
                "ssm send-command --instance-ids ",
                _q(instance),
                " --document-name AWS-RunShellScript --comment 'morca aws'",
                " --parameters ",
                _q(params),
                " --query Command.CommandId --output text",
            )
        )
    )
    var status = String()
    var ask = o.aws(
        String(
            "ssm get-command-invocation --command-id ",
            _q(id),
            " --instance-id ",
            _q(instance),
        )
    )
    for _ in range(900):
        # Until the instance has the command, there's no invocation yet.
        var got = capture(
            ["sh", "-c", String(ask, " --query Status --output text")]
        )
        status = String(got[1].strip())
        if got[0] == 0 and (
            status == "Success"
            or status == "Failed"
            or status == "Cancelled"
            or status == "TimedOut"
        ):
            break
        sleep(2.0)
    var text = _out(String(ask, " --query StandardOutputContent --output text"))
    print(text)
    var err = _out(String(ask, " --query StandardErrorContent --output text"))
    if err and err != "None":
        print(err)
    if status != "Success":
        print("morca aws: the command on", instance, "", status)
        return (3, text^)
    return (0, text^)


def _register(o: _Opts) raises -> Int:
    var flags = String()
    var pipelines = List[String]()
    var config_path = String()
    var no_config = False
    var i = 0
    while i < len(o.rest):
        var a = o.rest[i]
        if a == "--image":
            print("morca aws register: the image is the project's, from push")
            return 2
        if a == "--config" and i + 1 < len(o.rest):
            config_path = o.rest[i + 1]
            i += 2
            continue
        if a == "--no-config":
            no_config = True
            i += 1
            continue
        var valued = False
        for v in materialize[_REGISTER_VALUED]():
            if a == v:
                valued = True
        if valued and i + 1 < len(o.rest):
            flags.write(" ", _q(a), " ", _q(o.rest[i + 1]))
            i += 2
            continue
        if a.startswith("--"):
            flags.write(" ", _q(a))
        else:
            pipelines.append(a)
        i += 1
    if len(pipelines) == 0:
        print("morca aws register needs a pipeline, as named in pipelines/")
        return 2
    var outs = _outputs(o)
    var repo = _output(outs, "Repository")
    var tag = _tag(o)
    var reg = String(
        "docker exec scheduler morca register --image ",
        _q(String(repo, ":", tag)),
        flags,
    )
    # The project's morca.toml (morca.config), read and checked here and sent
    # whole, with its commit: the control instance has no checkout.
    if not no_config:
        if not config_path:
            config_path = getenv("MORCA_CONFIG")
        if not config_path and exists("morca.toml"):
            config_path = String("morca.toml")
        if not config_path:
            refuse_orca_toml()
    if config_path:
        var file = ProjectConfig.load(config_path)
        var text: String
        with open(config_path, "r") as f:
            text = f.read()
        var slash = config_path.rfind("/").or_else(-1)
        reg.write(
            " --config-b64 ",
            _q(b64encode(text)),
            " --config-name ",
            _q(String(config_path[byte = slash + 1 :])),
        )
        if file.commit:
            reg.write(" --config-commit ", _q(file.commit))
        if file.dirty:
            reg.write(" --config-dirty")
        print(
            "morca aws register: with",
            config_path,
            String("(sha256 ", file.hash[byte=:12], ")"),
        )
    else:
        reg.write(" --no-config")
    for p in pipelines:
        reg.write(" ", _q(String("/opt/morca/pipelines/", p)))
    var cmds: List[String] = [String("orca-refresh ", _q(tag)), reg^]
    return _ssm(o, _output(outs, "ControlInstance"), cmds)


def _app(o: _Opts) raises -> Int:
    if len(o.rest) != 1:
        print("morca aws app needs the app's name, a bin/<name>.mojo")
        return 2
    var name = o.rest[0]
    var outs = _outputs(o)
    var host = o.host
    if not host and name == "console":
        host = outs.get("ConsoleHostname", "")
    if not host:
        print("morca aws app needs --host")
        return 2
    var cmds = List[String]()
    if o.tag:
        cmds.append(String("orca-refresh ", _q(o.tag)))
    cmds.append(String("orca-app ", _q(name), " ", _q(host), " ", _q(o.port)))
    var code = _ssm(o, _output(outs, "ControlInstance"), cmds)
    if code == 0:
        print(name, " at https://", host, sep="")
    return code


def _down(o: _Opts) raises -> Int:
    if not o.yes:
        print(
            "morca aws down deletes the stack",
            o.stack,
            (
                "and everything in it: the control instance, its database,"
                " the repository and the buckets. Run it again with --yes."
            ),
        )
        return 2
    _run(
        o.aws(String("cloudformation delete-stack --stack-name ", _q(o.stack)))
    )
    var code = _system(
        o.aws(
            String(
                "cloudformation wait stack-delete-complete --stack-name ",
                _q(o.stack),
            )
        )
    )
    if code != 0:
        print(
            "morca aws: the stack didn't delete. A bucket or the repository"
            " that still holds something stays: empty it (aws s3 rm"
            " --recursive s3://<bucket>) and run down again."
        )
        return 3
    print("deleted the stack", o.stack)
    return 0


def aws_command(args: List[String]) raises -> Int:
    """`morca aws <cmd> ...`: `args` is the whole command line."""
    if len(args) < 3:
        print(AWS_USAGE)
        return 2
    var o = _Opts(args, 3)
    var cmd = args[2]
    if cmd == "up":
        return _up(o)
    if cmd == "push":
        return _push(o)
    if cmd == "register":
        return _register(o)
    if cmd == "app":
        return _app(o)
    if cmd == "status":
        return _status(o)
    if cmd == "down":
        return _down(o)
    print(AWS_USAGE)
    return 2
