#!/bin/sh
# Runs inside a clean Ubuntu container: installs the .deb given as $1, built with the
# $TOOLKIT toolkit, and checks that Emacs runs with the features it was built for;
# that it lives beside Ubuntu's emacs, first on users' PATH while /usr/bin/emacs and
# the compiling of Ubuntu's add-ons stay with Ubuntu's; and that removing it leaves
# nothing behind.
set -eu
export DEBIAN_FRONTEND=noninteractive

commands="emacs emacsclient etags ebrowse"
prefix=/opt/emacs-upstream
package=$(dpkg-deb -f "$1" Package)

# Features configure may leave out with only a warning. The ones it fails on when
# missing are listed too, so this stays the one list of what a build must have.
features="ACL CAIRO DBUS FREETYPE GIF GLIB GMP GNUTLS GPM HARFBUZZ JPEG LCMS2 LIBOTF
LIBSELINUX LIBSYSTEMD LIBXML2 M17N_FLT MODULES NATIVE_COMP NOTIFY INOTIFY PDUMPER PNG
RSVG SECCOMP SOUND SQLITE3 THREADS TIFF TOOLKIT_SCROLL_BARS TREE_SITTER WEBP X11 XDBE
XIM XINERAMA XINPUT2 XPM XRANDR ZLIB"
case $TOOLKIT in
    gtk3) features="$features GTK3 GSETTINGS" ;;
    lucid) features="$features LUCID XAW3D" ;;
esac

fail() {
    echo "FAIL: $*"
    exit 1
}

# Usage: link <path> <target>, fails unless <path> leads to <target> through the
# alternatives' own link in /etc/alternatives.
link() {
    via=$(readlink "$1" || true)
    to=$(readlink "$via" || true)
    if [ "$via" != /etc/alternatives/"${1##*/}" ] || [ "$to" != "$2" ]; then
        fail "$1 leads to '$via' and '$to', not $2"
    fi
}

# Usage: ours, fails unless every command and man page in /usr/bin leads here.
ours() {
    for p in $commands; do
        link /usr/bin/"$p" $prefix/bin/"$p"
        link /usr/share/man/man1/"$p".1.gz $prefix/share/man/man1/"$p".1.gz
    done
}

# Usage: found, fails unless a login shell and the desktop session both find every
# command here first, and look for desktop entries here first.
found() {
    for p in $commands; do
        got=$(bash -lc "command -v $p")
        [ "$got" = "$prefix/bin/$p" ] || fail "a login shell finds $p at '$got', not $prefix/bin/$p"
    done
    bash -lc 'echo "$XDG_DATA_DIRS"' | grep -q "^$prefix/share:" ||
        fail "login shells do not look for desktop entries in $prefix/share first"
    session=$(env -i PATH=/usr/bin:/bin HOME=/root \
        /usr/lib/systemd/user-environment-generators/30-systemd-environment-d-generator)
    for want in "PATH=$prefix/bin:" "XDG_DATA_DIRS=$prefix/share:"; do
        case $session in
            *"$want"*) ;;
            *) fail "the desktop session's environment lacks $want: $session" ;;
        esac
    done
}

apt-get update -qq
# A clean system has nothing the Depends line forgot. systemd is there for its
# environment.d generator, which sets up the desktop session's environment.
apt-get install -y -qq systemd "$1" >/dev/null
ours
found
grep -q "^ExecStart=$prefix/bin/emacs " /usr/lib/systemd/user/emacs-upstream.service ||
    fail "emacs-upstream.service does not start $prefix/bin/emacs"

emacs --version | head -1
emacsclient --version
etags --version | head -1
have=" $(emacs -Q --batch --eval '(princ system-configuration-features)') "
for f in $features; do
    case $have in
        *" $f "*) ;;
        *) fail "built without $f" ;;
    esac
done
echo "features: ok"
# Compiling a function at runtime is what Emacs does for every package a user
# installs, and it needs more than native-comp-available-p shows: gcc's own pieces.
emacs -Q --batch --eval '
(let ((checks `(("native-comp" . ,(native-comp-available-p))
                ("runtime native-compile" . ,(subrp (native-compile (quote (lambda (x) x)))))
                ("tree-sitter" . ,(treesit-available-p))
                ("sqlite" . ,(sqlite-available-p))
                ("gnutls" . ,(gnutls-available-p))
                ("svg" . ,(image-type-available-p (quote svg)))
                ("webp" . ,(image-type-available-p (quote webp))))))
  (dolist (c checks)
    (princ (format "%s: %s\n" (car c) (if (cdr c) "ok" "MISSING"))))
  (kill-emacs (if (seq-every-p (function cdr) checks) 0 1)))'

# Installing over itself runs the scripts of an upgrade: prerm, then postinst.
dpkg -i "$1" >/dev/null
ours
echo "upgrade: ok"

# With Ubuntu's emacs beside it, /usr/bin is Ubuntu's again, and an add-on is compiled
# by Ubuntu's emacs, for Ubuntu's emacs; users still find this one first.
apt-get install -y -qq emacs-nox elpa-dash >/dev/null
link /usr/bin/emacs /usr/bin/emacs-nox
for p in emacsclient etags ebrowse; do
    link /usr/bin/"$p" /usr/bin/"$p".emacs
done
found
ubuntu=$(emacs-nox -Q --batch --eval '(princ emacs-version)')
elc=$(find /usr/share/emacs/site-lisp/elpa -name dash.elc)
grep -aq "^;;; in Emacs version $ubuntu\$" "$elc" ||
    fail "$elc was not compiled by Ubuntu's Emacs $ubuntu"
echo "beside Ubuntu's emacs: ok"

apt-get purge -y -qq "$package" >/dev/null
link /usr/bin/emacs /usr/bin/emacs-nox
for f in $prefix /etc/profile.d/emacs-upstream.sh /usr/lib/environment.d/990-emacs-upstream.conf \
    /usr/lib/systemd/user/emacs-upstream.service; do
    [ ! -e "$f" ] || fail "$f is left behind"
done
got=$(bash -lc 'command -v emacs')
[ "$got" = /usr/bin/emacs ] || fail "a login shell finds emacs at '$got', not /usr/bin/emacs"
echo "removed, back to Ubuntu's emacs: ok"
