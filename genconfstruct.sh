#!/bin/sh
set -eu

cat<<EOF
let zs = ""
type rgb = (float * float * float)
and rgba = (float * float * float * float)
and fitmodel = | FitWidth | FitProportional | FitPage
and irect = (int * int * int * int)
and colorspace = | Rgb | Gray
and keymap =
  | KMinsrt of key | KMinsrl of key list | KMmulti of (key list * key list)
and key = (int * int)
and keyhash = (key, keymap) Hashtbl.t
and keystate = | KSnone | KSinto of (key list * key list)
and css = string and dcf = string and hcs = string
and columns =
  | Csingle of singlecolumn
  | Cmulti of multicolumns
  | Csplit of splitcolumns
and mark =
  | MarkPage
  | MarkBlock
  | MarkLine
  | MarkWord
and multicolumns = (multicol * pagegeom)
and singlecolumn = pagegeom
and splitcolumns = (columncount * pagegeom)
and pagegeom = (pdimno * x * y * (pageno * w * h * leftx)) array
and multicol = (columncount * covercount * covercount)
and columncount = int
and pdimno = int and pageno = int
and x = int and y = int and leftx = int and w = int and  h = int
and covercount = int
and memsize = int and texcount = int
and sliceheight = int
and zoom = float
let scrollbvv = 1 and scrollbhv = 2
EOF

init=
assi=
g() {
    printf "mutable $1:$2;"
    init="$init $1=$3;"
    assi="$assi dst.$1 <- src.$1;"
}
i() { g "$1" int "$2"; }
b() { g "$1" bool "$2"; }
f() { g "$1" float "$2"; }
s() { g "$1" string "$2"; }
K() {
    printf "mutable $1:$2;\n"
    init="$init $1=$3;"
    assi="$assi dst.keyhashes <- copykeyhashes src;"
}
P() {
    printf "mutable $1 : float option;\n"
    init="$init $1=None;"
    assi="$assi dst.pax <- if src.pax = None then None else Some 0.0;"
}
echo "type conf = {"
i scrollbw 7
i scrollh 12
i scrollb "scrollbhv lor scrollbvv"
b icase true
b preload true
i pagebias 0
b verbose false
b debug false
i scrollstep 24
i hscrollstep 24
b maxhfit true
i autoscrollstep 2
b hlinks false
b underinfo false
i interpagespace 2
f zoom 1.0
b presentation false
i angle 0
i cwinw 1800
i cwinh 1500
g fitmodel fitmodel FitProportional
b trimmargins false
g trimfuzz irect "(0,0,0,0)"
g memlimit memsize "128 lsl 20"
g texcount texcount 256
g sliceheight sliceheight 24
g thumbw w 76
g bgcolor rgb "(0.5, 0.5, 0.5)"
g papercolor rgba "(1.0, 1.0, 1.0, 0.0)"
g sbarcolor rgba "(0.64, 0.64, 0.64, 0.7)"
g sbarhndlcolor rgba "(0.0, 0.0, 0.0, 0.7)"
g texturecolor rgba "(0.0, 0.0, 0.0, 0.0)"
i tilew 2048
i tileh 2048
g mustoresize memsize "256 lsl 20"
i aalevel 8
s urilauncher "{|$uopen|}"
s pathlauncher "{|$print|}"
g colorspace colorspace Rgb
b invert false
f colorscale 1.
g columns columns "Csingle [||]"
g beyecolumns "columncount option" None
s selcmd "{|$clip|}"
s pastecmd "{|$paste|}"
s paxcmd '{|echo PAX "%s">&2|}'
s passcmd zs
s savecmd zs
b updatecurs true
K keyhashes '(string * keyhash) list' \
'(let mk n = (n, Hashtbl.create 1) in
      [ mk "global"; mk "info" ; mk "help"; mk "outline"; mk "listview"
      ; mk "birdseye"; mk "textentry"; mk "links"; mk "view" ])'
i hfsize 'Wsi.fontsizescale 12'
f pgscale 1.
b wheelbypage false
s stcmd "{|echo SyncTex|}"
b riani false
g paxmark mark MarkWord
b leftscroll false
s title zs
f lastvisit 0.0
b annotinline true
b coarseprespos false
g css css zs
b usedoccss true
s key zs
P pax
g dcf dcf zs
s hcs "{|aoeuidhtns|}"
i rlw 420
i rlh 595
i rlem 11

cat <<EOF
}
let copykeyhashes c = List.map (fun (k, v) -> k, Hashtbl.copy v) c.keyhashes
let defconf = {$init}
let setconf dst src = $assi;
EOF
