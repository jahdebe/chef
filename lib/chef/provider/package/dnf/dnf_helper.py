#!/usr/bin/env python3
# vim: tabstop=8 expandtab shiftwidth=4 softtabstop=4

import sys
import dnf
import hawkey
import signal
import os
import json

base = None

def get_sack():
    global base
    if base is None:
        base = dnf.Base()
        conf = base.conf
        conf.read()
        conf.installroot = '/'
        conf.assumeyes = True
        subst = conf.substitutions
        subst.update_from_etc(conf.installroot)
        try:
            base.init_plugins()
            base.pre_configure_plugins()
        except AttributeError:
            pass
        base.read_all_repos()
        repos = base.repos

        if 'repos' in command:
            for repo_pattern in command['repos']:
                if 'enable' in repo_pattern:
                    for repo in repos.get_matching(repo_pattern['enable']):
                        repo.enable()
                if 'disable' in repo_pattern:
                    for repo in repos.get_matching(repo_pattern['disable']):
                        repo.disable()

        try:
            base.configure_plugins()
        except AttributeError:
            pass
        base.fill_sack(load_system_repo='auto')
    return base.sack

# FIXME: leaks memory and does not work
def flushcache():
    try:
        os.remove('/var/cache/dnf/@System.solv')
    except OSError:
        pass
    get_sack().load_system_repo(build_cache=True)

def version_tuple(versionstr):
    e = '0'
    v = None
    r = None
    colon_index = versionstr.find(':')
    if colon_index > 0:
        e = str(versionstr[:colon_index])
    dash_index = versionstr.find('-')
    if dash_index > 0:
        tmp = versionstr[colon_index + 1:dash_index]
        if tmp != '':
            v = tmp
        arch_index = versionstr.find('.', dash_index)
        if arch_index > 0:
            r = versionstr[dash_index + 1:arch_index]
        else:
            r = versionstr[dash_index + 1:]
    else:
        tmp = versionstr[colon_index + 1:]
        if tmp != '':
            v = tmp
    return (e, v, r)

def versioncompare(versions):
    sack = get_sack()
    if (versions[0] is None) or (versions[1] is None):
      outpipe.write('0\n')
      outpipe.flush()
    else:
      evr_comparison = dnf.rpm.rpm.labelCompare(version_tuple(versions[0]), version_tuple(versions[1]))
      outpipe.write('{}\n'.format(evr_comparison))
      outpipe.flush()

def query(command):
    sack = get_sack()

    subj = dnf.subject.Subject(command['provides'])
    q = subj.get_best_query(sack, with_provides=True)

    if command['action'] == "whatinstalled":
        q = q.installed()

    if command['action'] == "whatavailable":
        q = q.available()

    # only apply the default arch query filter if it returns something
    archq = q.filter(arch=[ 'noarch', hawkey.detect_arch() ])
    if len(archq.run()) > 0:
        q = archq

    pkgs = q.latest(1).run()

    if not pkgs:
        outpipe.write('{} nil nil\n'.format(command['provides'].split().pop(0)))
        outpipe.flush()
    else:
        # make sure we picked the package with the highest version
        pkgs.sort
        pkg = pkgs.pop()
        outpipe.write('{} {}:{}-{} {}\n'.format(pkg.name, pkg.epoch, pkg.version, pkg.release, pkg.arch))
        outpipe.flush()

# the design of this helper is that it should try to be 'brittle' and fail hard and exit in order
# to keep process tables clean.  additional error handling should probably be added to the retry loop
# on the ruby side.
def exit_handler(signal, frame):
    if base is not None:
        base.close()
    sys.exit(0)

def setup_exit_handler():
    signal.signal(signal.SIGINT, exit_handler)
    signal.signal(signal.SIGHUP, exit_handler)
    signal.signal(signal.SIGPIPE, exit_handler)
    signal.signal(signal.SIGQUIT, exit_handler)

if len(sys.argv) < 3:
  inpipe = sys.stdin
  outpipe = sys.stdout
else:
  inpipe = os.fdopen(int(sys.argv[1]), "r")
  outpipe = os.fdopen(int(sys.argv[2]), "w")

try:
    while 1:
        # kill self if we get orphaned (tragic)
        ppid = os.getppid()
        if ppid == 1:
            raise RuntimeError("orphaned")

        setup_exit_handler()
        line = inpipe.readline()

        try:
            command = json.loads(line)
        except ValueError:
            raise RuntimeError("bad json parse")

        if command['action'] == "whatinstalled":
            query(command)
        elif command['action'] == "whatavailable":
            query(command)
        elif command['action'] == "versioncompare":
            versioncompare(command['versions'])
        else:
            raise RuntimeError("bad command")
finally:
    if base is not None:
        base.closeRpmDB()
