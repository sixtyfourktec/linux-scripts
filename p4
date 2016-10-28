#!/usr/bin/env python
#
# Copyright (c) 2016 Christian Poetzsch
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
# of the Software, and to permit persons to whom the Software is furnished to do
# so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# Helper script for the lack of functionality in perforce's commandline utility
# p4.
#
# This adds a couple of additional parameters like:
#
#  patch/diff2_patch: 
#   - create a unified patch out of the current ws changes or a given changeset
#   - this included added/deleted files
#   - this works with integrated changesets
#  apply:
#   - apply a unified patch and open existing files for edit if necessary
#  revert:
#   - revert a changeset locally
#  diff*/print/describe:
#   - colorize
#  listsh:
#   - list the shelves of the configured user
#
# You can pretend 'real' to the command line to run p4 unmodified.

import os
import sys
import errno
import re
import subprocess
import tempfile

# config

# Which user should be used for commands expecting it?
USER='christian.potzsch'
# Where does the real p4 executable live?
P4=os.path.join(os.environ['HOME'], 'local/bin/private/p4')

# helpers

def _execute(cmd, add_env=None, std_print=True):
    std_out = None
    env = os.environ.copy()
    env['LC_ALL'] = 'en_US.UTF-8'
    env['LANGUAGE'] = 'en_US.UTF-8'

    # add any user provided environment vars
    if add_env != None:
        env.update(add_env)

    # if the user didn't provide a list within a list then fix this
    if type(cmd[0]) is str:
        cmd = [cmd]

    # connect the first cmd with the second cmd and so on
    i = None
    o = subprocess.PIPE
    for c in cmd:
#        print >> sys.stderr, c
        # if the user wants the data printed to screen we need to remove the
        # out pipe on the last cmd
        if std_print and c is cmd[-1]:
            o = None
        p = subprocess.Popen(c,
                stdout=o,
                stdin=i,
                close_fds=True,
                env=env)
        i = p.stdout

    # save the final output of the last cmd
    if not std_print:
        std_out = p.stdout.read()

    rc = p.wait()

    return [rc, std_out]

def execute(cmd, add_env=None):
    return _execute(cmd, add_env=add_env, std_print=True)[0]

def execute_stdout(cmd, add_env=None):
    return _execute(cmd, add_env=add_env, std_print=False)[1]

def p4_where(): # return local and remote path without the dots
    s = execute_stdout([P4, 'where'])
    e = s.split()
    return [e[0][:-4], e[2][:-4]]

def print_color_diff(a):
    #if sys.stdout.isatty():
    #    p = subprocess.Popen(['colordiff'], stdin=subprocess.PIPE)
    #    p.stdin.write('\n' + a)
    #else:
        return a + '\n'

def print_diff_add(f, t):
    r = '--- /dev/null\n'
    r += '+++ b/' + f + '\n'
    r += '@@ -0,0 +1,' + str(t.count('\n')) + ' @@' + '\n'
    return r + print_color_diff( re.sub(r'(.*)(\n)', r'+\1\2', t))

def print_diff_del(f, t):
    r = '--- a/' + f + '\n'
    r += '+++ /dev/null' + '\n'
    r += '@@ -1,' + str(t.count('\n')) + ' +0,0 @@' + '\n'
    return r + print_color_diff( re.sub(r'(.*)(\n)', r'-\1\2', t))

# options

def list_shelves(a):
    return execute([P4, 'changes', '-u', USER, '-s', 'shelved'] + a)

def print_changelist(a):
    # Don't format if we print to a file
    if '-o' in a or not sys.stdout.isatty():
        return execute([P4, 'print'] + a)
    else:
        return execute([[P4, 'print'] + a, ['sed', 's/\t/    /g'], ['pygmentize', '-g', '-f', 'terminal256'], ['less']])

def status(a):
#    execute([P4, 'diff', '-sa'] + a)
#    execute([P4, 'diff', '-sa'] + a)
    execute([P4, 'opened'] + a)
    return execute([P4, 'status'] + a)

def unchanged(a):
    return execute([P4, 'diff', '-sr'] + a)

def annotate(a):
    return execute([P4, 'annotate', '-i', '-c'] + a)

def describe(a):
    return execute([[P4, 'describe', '-du'] + a, ['sed', 's/\t/    /g'], ['colordiff'], ['less']])

def diff(a):
    return execute([[P4, 'diff'] + a, ['less']], add_env={'P4DIFF': 'colordiff -u --tabsize=4 -t'})

def patch_changelist(a, h):
    [rpath, lpath] = p4_where()
    s = execute_stdout([P4, 'describe', '-S', '-s'] + a)
    it = re.finditer(r'... ' + rpath + '/(.*)#(\d+?) (.*)', s)
    for m in it:
        [fname, rev, cmd] = m.groups()
        ff = rpath + '/' + fname # full path
        revp = str(int(rev) - 1) # previous revision
        if cmd in ['add', 'branch', 'move/add']:
            t = execute_stdout([P4, 'print', '-q', ff + '#' + rev])
            h.write(print_diff_add(fname, t))
        elif cmd in ['delete', 'move/delete']:
            t = execute_stdout([P4, 'print', '-q', ff + '#' + revp])
            h.write(print_diff_del(fname, t))
        elif cmd in ['edit', 'integrate']:
            t = execute_stdout([P4, 'diff2', '-du', ff + '#' + revp, ff + '#' + rev])
            # replace all headers
            t = re.sub(r'==== ' + rpath + '(.*?)#\d+? \(x?text\) - ' + rpath + '.*?#\d+ \(x?text\) ==== content\n',
                    r'--- a\1\n+++ b\1\n', t)
            h.write(print_color_diff(t))
        else:
            print "Unsupported command found: " + cmd
            return 1
    return 0

def patch_workspace(a, h):
    [rpath, lpath] = p4_where()
    e = execute_stdout([P4, 'opened'] + a)
    it = re.finditer(rpath + '/(.*)#(\d+?) - (\w+?) .*\n', e)
    for m in it:
        [fname, rev, cmd] = m.groups()
        if cmd in ['add', 'branch']:
            t = open(fname).read()
            h.write(print_diff_add(fname, t))
        elif cmd == 'delete':
            t = execute_stdout([P4, 'print', '-q', rpath + '/' + fname + '#' + rev])
            h.write(print_diff_del(fname, t))
        elif cmd in ['edit', 'integrate']:
            t = execute_stdout([P4, 'diff', '-du', fname])
            # replace all headers
            t = re.sub(r'--- (?:' + rpath + ')(.*?)\s+.*\n',
                    r'--- a\1\n', t)
            t = re.sub(r'\+\+\+ (?:' + lpath + ')(.*?)\s+.*\n',
                    r'+++ b\1\n', t)
            h.write(print_color_diff(t))
        else:
            print "Unsupported command found: " + c
            return 1
    return 0

def patch(a):
    # Use describe if the user provided a CL. Else create a patch against the
    # current ws.
    if len(a) > 0 and a[0].isdigit():
        return patch_changelist(a, sys.stdout)
    else:
        return patch_workspace(a, sys.stdout)

def diff2_patch(a):
    if len(a) < 2:
        sys.stderr.write('To less arguments\n')
        return 1
    [lfile, lrev] = re.findall(r'([^@]*)(@\d+)?', a[0])[0]
    [rfile, rrev] = re.findall(r'([^@]*)(@\d+)?', a[1])[0]
    ll = len(lfile) - 1
    lr = len(rfile) - 1
    # figure out which part of the path is the same
    for l in range(0, min(ll, lr)):
        if lfile[ll-l] != rfile[lr-l]:
            break
    [lpath, lfile] = [lfile[:ll-l+1], lfile[ll-l+1:]]
    [rpath, rfile] = [rfile[:lr-l+1], rfile[lr-l+1:]]
    h = sys.stdout

    s = execute_stdout([P4, 'diff2', '-ds', lpath + lfile + lrev, rpath + rfile + rrev])
    it = re.finditer(r'==== (.*) - (.*) ===(.*)', s)
    for m in it:
        [left, right, cmd] = m.groups()
        if cmd == '= identical':
            continue
#        print [left, right, cmd]
        if left == '<none>':
            [path, rev] = re.findall(rpath + r'/(.*)#(.*)', right)[0]
            t = execute_stdout([P4, 'print', '-q', right])
            h.write(print_diff_add(path, t))
        elif right == '<none>':
            [path, rev] = re.findall(lpath + r'/(.*)#(.*)', left)[0]
            t = execute_stdout([P4, 'print', '-q', left])
            h.write(print_diff_del(path, t))
        else:
            [p1, t1] = re.findall(r'(.*#.*) \((.*)\)', left)[0]
            [p2, t2] = re.findall(r'(.*#.*) \((.*)\)', right)[0]
            if t1 == "text" and t2 == "text":
                t = execute_stdout([P4, 'diff2', '-du', p1, p2])
                # replace all headers
                t = re.sub(r'==== ' + lpath + '/(.*?)#\d+? \(x?text\) - ' + rpath + '/.*?#\d+ \(x?text\) ==== content\n',
                        r'--- a/\1\n+++ b/\1\n', t)
                h.write(print_color_diff(t))
    return 0

def apply_changelist(a):
    h = tempfile.NamedTemporaryFile(mode='w')
    e = patch_changelist(a, h)
    if not e:
        h.flush()
        e = execute(['patch', '-p1', '-g1', '-i', h.name]);
    h.close()
    return e

def apply(a):
    # Use describe if the user provided a CL. Else apply the patch from a given
    # file.
    if len(a) > 0 and a[0].isdigit():
        return apply_changelist(a)
    else:
        return execute(['patch', '-p1', '-g1', '-i', a[0]]);

def revert_changelist(a):
    h = tempfile.NamedTemporaryFile(mode='w')
    e = patch_changelist(a, h)
    if not e:
        h.flush()
        e = execute(['patch', '-R', '-p1', '-g1', '-i', h.name]);
    h.close()
    return e

def revert(a):
    # Use describe if the user provided a CL. Else use the default revert
    # command.
    if len(a) > 0 and a[0].isdigit():
        return revert_changelist(a)
    else:
        return execute([P4, 'revert'] + a)

def main():
    a = sys.argv
    try:
        if len(a) > 1:
            if a[1] == 'listsh':
                return list_shelves(a[2:])
            elif a[1] == 'print':
                return print_changelist(a[2:])
            elif a[1] == 'status':
                return status(a[2:])
            elif a[1] == 'unchanged':
                return unchanged(a[2:])
            elif a[1] == 'annotate':
                return annotate(a[2:])
            elif a[1] == 'describe':
                return describe(a[2:])
            elif a[1] == 'diff':
                return diff(a[2:])
            elif a[1] == 'patch':
                return patch(a[2:])
            elif a[1] == 'diff2_patch':
                return diff2_patch(a[2:])
            elif a[1] == 'apply':
                return apply(a[2:])
            elif a[1] == 'revert':
                return revert(a[2:])
            elif a[1] == 'real':
                a.pop(1)
        return execute([P4] + a[1:])
    # catch broken pipe from less
    except IOError as e:
        if e.errno != errno.EPIPE:
            return e.errno
    # catch CTRL+C
    except KeyboardInterrupt:
        # fix terminal breakage after ctrl+c
        os.system('stty sane')
        sys.stdout.write('\n')
        return 4
    # return any other error code from subprocesses
    except subprocess.CalledProcessError, e:
        return e.returncode

    return 0

if __name__ == "__main__":
    sys.exit(main())
