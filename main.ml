type under =
    | Unone
    | Ulinkuri of string
    | Ulinkgoto of (int * int)
    | Utext of facename
and facename = string;;

let log fmt = Printf.kprintf prerr_endline fmt;;
let dolog fmt = Printf.kprintf prerr_endline fmt;;

external init : Unix.file_descr -> unit = "ml_init";;
external draw : (int * int * int * int * bool) -> string  -> unit = "ml_draw";;
external seltext : string -> (int * int * int * int) -> int -> unit =
  "ml_seltext";;
external copysel : string ->  unit = "ml_copysel";;
external getpagewh : int -> float array = "ml_getpagewh";;
external whatsunder : string -> int -> int -> under = "ml_whatsunder";;

type mstate = Msel of ((int * int) * (int * int)) | Mnone;;

type 'a circbuf =
    { store : 'a array
    ; mutable rc : int
    ; mutable wc : int
    ; mutable len : int
    }
;;

type textentry = (char * string * onhist option * onkey * ondone)
and onkey = string -> int -> te
and ondone = string -> unit
and onhist = histcmd -> string
and histcmd = HCnext | HCprev | HCfirst | HClast
and te =
    | TEstop
    | TEdone of string
    | TEcont of string
    | TEswitch of textentry
;;

let cbnew n v =
  { store = Array.create n v
  ; rc = 0
  ; wc = 0
  ; len = 0
  }
;;

let cblen b = Array.length b.store;;

let cbput b v =
  let len = cblen b in
  b.store.(b.wc) <- v;
  b.wc <- (b.wc + 1) mod len;
  b.len <- min (b.len + 1) len;
;;

let cbpeekw b = b.store.(b.wc);;

let cbget b dir =
  if b.len = 0
  then b.store.(0)
  else
    let rc = b.rc + dir in
    let rc = if rc = -1 then b.len - 1 else rc in
    let rc = if rc = b.len then 0 else rc in
    b.rc <- rc;
    b.store.(rc);
;;

let cbrfollowlen b =
  b.rc <- b.len;
;;

let cbclear b v =
  b.len <- 0;
  Array.fill b.store 0 (Array.length b.store) v;
;;

type layout =
    { pageno : int
    ; pagedimno : int
    ; pagew : int
    ; pageh : int
    ; pagedispy : int
    ; pagey : int
    ; pagevh : int
    }
;;

type conf =
    { mutable scrollw : int
    ; mutable scrollh : int
    ; mutable icase : bool
    ; mutable preload : bool
    ; mutable pagebias : int
    ; mutable verbose : bool
    ; mutable scrollincr : int
    ; mutable maxhfit : bool
    ; mutable crophack : bool
    ; mutable autoscroll : bool
    ; mutable showall : bool
    ; mutable hlinks : bool
    ; mutable underinfo : bool
    ; mutable interpagespace : int
    ; mutable margin : int
    ; mutable presentation : bool
    }
;;

type outline = string * int * int * float;;
type outlines =
    | Oarray of outline array
    | Olist of outline list
    | Onarrow of outline array * outline array
;;

type rect = (float * float * float * float * float * float * float * float);;

type state =
    { mutable csock : Unix.file_descr
    ; mutable ssock : Unix.file_descr
    ; mutable w : int
    ; mutable h : int
    ; mutable winw : int
    ; mutable rotate : int
    ; mutable y : int
    ; mutable ty : float
    ; mutable maxy : int
    ; mutable layout : layout list
    ; pagemap : ((int * int * int), string) Hashtbl.t
    ; mutable pages : (int * int * int) list
    ; mutable pagecount : int
    ; pagecache : string circbuf
    ; mutable rendering : bool
    ; mutable mstate : mstate
    ; mutable searchpattern : string
    ; mutable rects : (int * int * rect) list
    ; mutable rects1 : (int * int * rect) list
    ; mutable text : string
    ; mutable fullscreen : (int * int) option
    ; mutable textentry : textentry option
    ; mutable outlines : outlines
    ; mutable outline : (bool * int * int * outline array * string) option
    ; mutable bookmarks : outline list
    ; mutable path : string
    ; mutable password : string
    ; mutable invalidated : int
    ; mutable colorscale : float
    ; hists : hists
    }
and hists =
    { pat : string circbuf
    ; pag : string circbuf
    ; nav : float circbuf
    }
;;

let conf =
  { scrollw = 5
  ; scrollh = 12
  ; icase = true
  ; preload = true
  ; pagebias = 0
  ; verbose = false
  ; scrollincr = 24
  ; maxhfit = true
  ; crophack = false
  ; autoscroll = false
  ; showall = false
  ; hlinks = false
  ; underinfo = false
  ; interpagespace = 2
  ; margin = 0
  ; presentation = false
  }
;;

let state =
  { csock = Unix.stdin
  ; ssock = Unix.stdin
  ; w = 900
  ; h = 900
  ; winw = 900
  ; rotate = 0
  ; y = 0
  ; ty = 0.0
  ; layout = []
  ; maxy = max_int
  ; pagemap = Hashtbl.create 10
  ; pagecache = cbnew 10 ""
  ; pages = []
  ; pagecount = 0
  ; rendering = false
  ; mstate = Mnone
  ; rects = []
  ; rects1 = []
  ; text = ""
  ; fullscreen = None
  ; textentry = None
  ; searchpattern = ""
  ; outlines = Olist []
  ; outline = None
  ; bookmarks = []
  ; path = ""
  ; password = ""
  ; invalidated = 0
  ; hists =
      { nav = cbnew 100 0.0
      ; pat = cbnew 20 ""
      ; pag = cbnew 10 ""
      }
  ; colorscale = 1.0
  }
;;

let vlog fmt =
  if conf.verbose
  then
    Printf.kprintf prerr_endline fmt
  else
    Printf.kprintf ignore fmt
;;

let writecmd fd s =
  let len = String.length s in
  let n = 4 + len in
  let b = Buffer.create n in
  Buffer.add_char b (Char.chr ((len lsr 24) land 0xff));
  Buffer.add_char b (Char.chr ((len lsr 16) land 0xff));
  Buffer.add_char b (Char.chr ((len lsr  8) land 0xff));
  Buffer.add_char b (Char.chr ((len lsr  0) land 0xff));
  Buffer.add_string b s;
  let s' = Buffer.contents b in
  let n' = Unix.write fd s' 0 n in
  if n' != n then failwith "write failed";
;;

let readcmd fd =
  let s = "xxxx" in
  let n = Unix.read fd s 0 4 in
  if n != 4 then failwith "incomplete read(len)";
  let len = 0
    lor (Char.code s.[0] lsl 24)
    lor (Char.code s.[1] lsl 16)
    lor (Char.code s.[2] lsl  8)
    lor (Char.code s.[3] lsl  0)
  in
  let s = String.create len in
  let n = Unix.read fd s 0 len in
  if n != len then failwith "incomplete read(data)";
  s
;;

let yratio y =
  if y = state.maxy
  then 1.0
  else float y /. float state.maxy
;;

let makecmd s l =
  let b = Buffer.create 10 in
  Buffer.add_string b s;
  let rec combine = function
    | [] -> b
    | x :: xs ->
        Buffer.add_char b ' ';
        let s =
          match x with
          | `b b -> if b then "1" else "0"
          | `s s -> s
          | `i i -> string_of_int i
          | `f f -> string_of_float f
          | `I f -> string_of_int (truncate f)
        in
        Buffer.add_string b s;
        combine xs;
  in
  combine l;
;;

let wcmd s l =
  let cmd = Buffer.contents (makecmd s l) in
  writecmd state.csock cmd;
;;

let calcheight () =
  let rec f pn ph fh l =
    match l with
    | (n, _, h) :: rest ->
        let fh = fh + (n - pn) * (ph + conf.interpagespace) in
        f n h fh rest

    | [] ->
        let fh = fh + ((ph + conf.interpagespace) * (state.pagecount - pn)) in
        max 0 fh
  in
  let fh = f 0 0 0 state.pages in
  fh + (if conf.presentation then conf.interpagespace else 0);
;;

let getpageyh pageno =
  let inc = if conf.presentation then conf.interpagespace else 0 in
  let rec f pn ph y l =
    match l with
    | (n, _, h) :: rest ->
        if n >= pageno
        then
          y + (pageno - pn) * (ph + conf.interpagespace), h
        else
          let y = y + (n - pn) * (ph + conf.interpagespace) in
          f n h y rest

    | [] ->
        y + (pageno - pn) * (ph + conf.interpagespace) + inc, ph
  in
  f 0 0 0 state.pages;
;;

let getpagey pageno = fst (getpageyh pageno);;

let layout y sh =
  let ips = conf.interpagespace in
  let rec f ~pageno ~pdimno ~prev ~vy ~py ~dy ~pdims ~cacheleft ~accu =
    if pageno = state.pagecount || cacheleft = 0
    then accu
    else
      let ((_, w, h) as curr), rest, pdimno =
        match pdims with
        | ((pageno', _, _) as curr) :: rest when pageno' = pageno ->
            curr, rest, pdimno + 1
        | _ ->
            prev, pdims, pdimno
      in
      let pageno' = pageno + 1 in
      if py + h > vy
      then
        let py' = vy - py in
        let vh = h - py' in
        if dy + vh > sh
        then
          let vh = sh - dy in
          if vh <= 0
          then
            accu
          else
            let e =
              { pageno = pageno
              ; pagedimno = pdimno
              ; pagew = w
              ; pageh = h
              ; pagedispy = dy
              ; pagey = py'
              ; pagevh = vh
              }
            in
            e :: accu
        else
          let e =
            { pageno = pageno
            ; pagedimno = pdimno
            ; pagew = w
            ; pageh = h
            ; pagedispy = dy
            ; pagey = py'
            ; pagevh = vh
            }
          in
          let accu = e :: accu in
          f ~pageno:pageno'
            ~pdimno
            ~prev:curr
            ~vy:(vy + vh)
            ~py:(py + h)
            ~dy:(dy + vh + ips)
            ~pdims:rest
            ~cacheleft:(pred cacheleft)
            ~accu
      else (
        let py' = vy - py in
        let vh = h - py' in
        let t = ips + vh in
        let dy, py = if t < 0 then 0, py + h + ips else t, py + h - vh in
        f ~pageno:pageno'
          ~pdimno
          ~prev:curr
          ~vy
          ~py
          ~dy
          ~pdims:rest
          ~cacheleft
          ~accu
      )
  in
  if state.invalidated = 0
  then
    let vy, py, dy =
      if conf.presentation
      then (
        if y < ips
        then
          y, y, ips - y
        else
          y - ips, 0, 0
      )
      else
        y, 0, 0
    in
    let accu =
      f
        ~pageno:0
        ~pdimno:~-1
        ~prev:(0,0,0)
        ~vy
        ~py
        ~dy
        ~pdims:state.pages
        ~cacheleft:(cblen state.pagecache)
        ~accu:[]
    in
    state.maxy <- calcheight ();
    List.rev accu
  else
    []
;;

let clamp incr =
  let y = state.y + incr in
  let y = max 0 y in
  let y = min y (state.maxy - (if conf.maxhfit then state.h else 0)) in
  y;
;;

let getopaque pageno =
  try Some (Hashtbl.find state.pagemap (pageno + 1, state.w, state.rotate))
  with Not_found -> None
;;

let cache pageno opaque =
  Hashtbl.replace state.pagemap (pageno + 1, state.w, state.rotate) opaque
;;

let validopaque opaque = String.length opaque > 0;;

let render l =
  match getopaque l.pageno with
  | None when not state.rendering ->
      state.rendering <- true;
      cache l.pageno "";
      wcmd "render" [`i (l.pageno + 1)
                    ;`i l.pagedimno
                    ;`i l.pagew
                    ;`i l.pageh];

  | _ -> ()
;;

let loadlayout layout =
  let rec f all = function
    | l :: ls ->
        begin match getopaque l.pageno with
        | None -> render l; f false ls
        | Some opaque -> f (all && validopaque opaque) ls
        end
    | [] -> all
  in
  f (layout <> []) layout;
;;

let preload () =
  if conf.preload
  then
    let evictedvisible =
      let evictedopaque = cbpeekw state.pagecache in
      List.exists (fun l ->
        match getopaque l.pageno with
        | Some opaque when validopaque opaque ->
            evictedopaque = opaque
        | otherwise -> false
      ) state.layout
    in
    if not evictedvisible
    then
      let y = if state.y < state.h then 0 else state.y - state.h in
      let pages = layout y (state.h*3) in
      List.iter render pages;
;;

let gotoy y =
  let y = max 0 y in
  let y = min state.maxy y in
  let pages = layout y state.h in
  let ready = loadlayout pages in
  state.ty <- yratio y;
  if conf.showall
  then (
    if ready
    then (
      state.layout <- pages;
      state.y <- y;
      Glut.postRedisplay ();
    )
  )
  else (
    state.layout <- pages;
    state.y <- y;
    Glut.postRedisplay ();
  );
  preload ();
;;

let addnav () =
  cbput state.hists.nav (yratio state.y);
  cbrfollowlen state.hists.nav;
;;

let getnav () =
  let y = cbget state.hists.nav ~-1 in
  truncate (y *. float state.maxy)
;;

let gotopage n top =
  let y, h = getpageyh n in
  addnav ();
  gotoy (y + (truncate (top *. float h)));
;;

let gotopage1 n top =
  let y = getpagey n in
  addnav ();
  gotoy (y + top);
;;

let invalidate () =
  state.layout <- [];
  state.pages <- [];
  state.rects <- [];
  state.rects1 <- [];
  state.invalidated <- state.invalidated + 1;
;;

let scalecolor c =
  let c = c *. state.colorscale in
  (c, c, c);
;;

let represent () =
  let rely =
    if conf.presentation
    then
      match state.pages with
      | [] -> yratio state.y
      | (_, _, h) :: _ ->
          let ips =
            let d = state.h - h in
            max 0 (d / 2)
          in
          let rely = yratio state.y in
          conf.interpagespace <- ips;
          rely
    else
      let rely = yratio state.y in
      conf.interpagespace <- 2;
      rely
  in
  state.maxy <- calcheight ();
  gotoy (truncate (float state.maxy *. rely));
;;

let reshape ~w ~h =
  let margin =
    let m = float conf.margin in
    let m = m *. (float w /. 20.) in
    let m = truncate m in
    if m*2 > (w - conf.scrollw) then 0 else m
  in
  state.winw <- w;
  let w = w - margin * 2 - conf.scrollw in
  state.w <- w;
  state.h <- h;
  GlMat.mode `modelview;
  GlMat.load_identity ();
  GlMat.mode `projection;
  GlMat.load_identity ();
  GlMat.rotate ~x:1.0 ~angle:180.0 ();
  GlMat.translate ~x:~-.1.0 ~y:~-.1.0 ();
  GlMat.scale3 (2.0 /. float w, 2.0 /. float state.h, 1.0);
  GlClear.color (scalecolor 1.0);
  GlClear.clear [`color];

  invalidate ();
  wcmd "geometry" [`i state.w; `i h];
;;

let showtext c s =
  GlDraw.viewport 0 0 state.winw state.h;
  GlDraw.color (0.0, 0.0, 0.0);
  GlMat.push ();
  GlMat.load_identity ();
  GlMat.rotate ~x:1.0 ~angle:180.0 ();
  GlMat.translate ~x:~-.1.0 ~y:~-.1.0 ();
  GlMat.scale3 (2.0 /. float state.winw, 2.0 /. float state.h, 1.0);
  GlDraw.rect
    (0.0, float (state.h - 18))
    (float (state.winw - conf.scrollw), float state.h)
  ;
  GlMat.pop ();
  let font = Glut.BITMAP_8_BY_13 in
  GlDraw.color (1.0, 1.0, 1.0);
  GlPix.raster_pos ~x:0.0 ~y:(float (state.h - 5)) ();
  Glut.bitmapCharacter ~font ~c:(Char.code c);
  String.iter (fun c -> Glut.bitmapCharacter ~font ~c:(Char.code c)) s;
;;

let enttext () =
  let len = String.length state.text in
  match state.textentry with
  | None ->
      if len > 0 then showtext ' ' state.text

  | Some (c, text, _, _, _) ->
      let s =
        if len > 0
        then
          text ^ " [" ^ state.text ^ "]"
        else
          text
      in
      showtext c s;
;;

let showtext c s =
  if true
  then (
    state.text <- Printf.sprintf "%c%s" c s;
    Glut.postRedisplay ();
  )
  else (
    showtext c s;
    Glut.swapBuffers ();
  )
;;

let act cmd =
  match cmd.[0] with
  | 'c' ->
      state.pages <- [];

  | 'D' ->
      state.rects <- state.rects1;
      Glut.postRedisplay ()

  | 'C' ->
      let n = Scanf.sscanf cmd "C %d" (fun n -> n) in
      state.pagecount <- n;
      state.invalidated <- state.invalidated - 1;
      if state.invalidated = 0
      then represent ()

  | 't' ->
      let s = Scanf.sscanf cmd "t %n"
        (fun n -> String.sub cmd n (String.length cmd - n))
      in
      Glut.setWindowTitle s

  | 'T' ->
      let s = Scanf.sscanf cmd "T %n"
        (fun n -> String.sub cmd n (String.length cmd - n))
      in
      if state.textentry = None
      then (
        state.text <- s;
        showtext ' ' s;
      )
      else (
        state.text <- s;
        Glut.postRedisplay ();
      )

  | 'V' ->
      if conf.verbose
      then
        let s = Scanf.sscanf cmd "V %n"
          (fun n -> String.sub cmd n (String.length cmd - n))
        in
        state.text <- s;
        showtext ' ' s;

  | 'F' ->
      let pageno, c, x0, y0, x1, y1, x2, y2, x3, y3 =
        Scanf.sscanf cmd "F %d %d %f %f %f %f %f %f %f %f"
          (fun p c x0 y0 x1 y1 x2 y2 x3 y3 ->
            (p, c, x0, y0, x1, y1, x2, y2, x3, y3))
      in
      let y = (getpagey pageno) + truncate y0 in
      addnav ();
      gotoy y;
      state.rects1 <- [pageno, c, (x0, y0, x1, y1, x2, y2, x3, y3)]

  | 'R' ->
      let pageno, c, x0, y0, x1, y1, x2, y2, x3, y3 =
        Scanf.sscanf cmd "R %d %d %f %f %f %f %f %f %f %f"
          (fun p c x0 y0 x1 y1 x2 y2 x3 y3 ->
            (p, c, x0, y0, x1, y1, x2, y2, x3, y3))
      in
      state.rects1 <-
        (pageno, c, (x0, y0, x1, y1, x2, y2, x3, y3)) :: state.rects1

  | 'r' ->
      let n, w, h, r, p =
        Scanf.sscanf cmd "r %d %d %d %d %s"
          (fun n w h r p -> (n, w, h, r, p))
      in
      Hashtbl.replace state.pagemap (n, w, r) p;
      let opaque = cbpeekw state.pagecache in
      if validopaque opaque
      then (
        let k =
          Hashtbl.fold
            (fun k v a -> if v = opaque then k else a)
            state.pagemap (-1, -1, -1)
        in
        wcmd "free" [`s opaque];
        Hashtbl.remove state.pagemap k
      );
      cbput state.pagecache p;
      state.rendering <- false;
      if conf.showall
      then gotoy (truncate (ceil (state.ty *. float state.maxy)))
      else (
        let visible = List.exists (fun l -> l.pageno + 1 = n) state.layout in
        if visible
        then gotoy state.y
        else (ignore (loadlayout state.layout); preload ())
      )

  | 'l' ->
      let (n, w, h) as pagelayout =
        Scanf.sscanf cmd "l %d %d %d" (fun n w h -> n, w, h)
      in
      state.pages <- pagelayout :: state.pages

  | 'o' ->
      let (l, n, t, h, pos) =
        Scanf.sscanf cmd "o %d %d %d %d %n" (fun l n t h pos -> l, n, t, h, pos)
      in
      let s = String.sub cmd pos (String.length cmd - pos) in
      let s =
        let l = String.length s in
        let b = Buffer.create (String.length s) in
        let rec loop pc2 i =
          if i = l
          then ()
          else
            let pc2 =
              match s.[i] with
              | '\xa0' when pc2 -> Buffer.add_char b ' '; false
              | '\xc2' -> true
              | c ->
                  let c = if Char.code c land 0x80 = 0 then c else '?' in
                  Buffer.add_char b c;
                  false
            in
            loop pc2 (i+1)
        in
        loop false 0;
        Buffer.contents b
      in
      let outline = (s, l, n, float t /. float h) in
      let outlines =
        match state.outlines with
        | Olist outlines -> Olist (outline :: outlines)
        | Oarray _ -> Olist [outline]
        | Onarrow _ -> Olist [outline]
      in
      state.outlines <- outlines

  | _ ->
      log "unknown cmd `%S'" cmd
;;

let now = Unix.gettimeofday;;

let idle () =
  let rec loop delay =
    let r, _, _ = Unix.select [state.csock] [] [] delay in
    begin match r with
    | [] ->
        if conf.autoscroll
        then begin
          let y = state.y + conf.scrollincr in
          let y = if y >= state.maxy then 0 else y in
          gotoy y;
          state.text <- "";
        end;

    | _ ->
        let cmd = readcmd state.csock in
        act cmd;
        loop 0.0
    end;
  in loop 0.001
;;

let onhist cb = function
  | HCprev  -> cbget cb ~-1
  | HCnext  -> cbget cb 1
  | HCfirst -> cbget cb ~-(cb.rc)
  | HClast  -> cbget cb (cb.len - 1 - cb.rc)
;;

let search pattern forward =
  if String.length pattern > 0
  then
    let pn, py =
      match state.layout with
      | [] -> 0, 0
      | l :: _ ->
          l.pageno, (l.pagey + if forward then 0 else 0*l.pagevh)
    in
    let cmd =
      let b = makecmd "search"
        [`b conf.icase; `i pn; `i py; `i (if forward then 1 else 0)]
      in
      Buffer.add_char b ',';
      Buffer.add_string b pattern;
      Buffer.add_char b '\000';
      Buffer.contents b;
    in
    writecmd state.csock cmd;
;;

let intentry text key =
  let c = Char.unsafe_chr key in
  match c with
  | '0' .. '9' ->
      let s = "x" in s.[0] <- c;
      let text = text ^ s in
      TEcont text

  | _ ->
      state.text <- Printf.sprintf "invalid char (%d, `%c')" key c;
      TEcont text
;;

let addchar s c =
  let b = Buffer.create (String.length s + 1) in
  Buffer.add_string b s;
  Buffer.add_char b c;
  Buffer.contents b;
;;

let textentry text key =
  let c = Char.unsafe_chr key in
  match c with
  | _ when key >= 32 && key < 127 ->
      let text = addchar text c in
      TEcont text

  | _ ->
      log "unhandled key %d char `%c'" key (Char.unsafe_chr key);
      TEcont text
;;

let rotate angle =
  state.rotate <- angle;
  invalidate ();
  wcmd "rotate" [`i angle];
;;

let optentry text key =
  let btos b = if b then "on" else "off" in
  let c = Char.unsafe_chr key in
  match c with
  | 's' ->
      let ondone s =
        try conf.scrollincr <- int_of_string s with exc ->
          state.text <- Printf.sprintf "bad integer `%s': %s"
            s (Printexc.to_string exc)
      in
      TEswitch ('#', "", None, intentry, ondone)

  | 'R' ->
      let ondone s =
        match try
            Some (int_of_string s)
          with exc ->
            state.text <- Printf.sprintf "bad integer `%s': %s"
              s (Printexc.to_string exc);
            None
        with
        | Some angle -> rotate angle
        | None -> ()
      in
      TEswitch ('^', "", None, intentry, ondone)

  | 'i' ->
      conf.icase <- not conf.icase;
      TEdone ("case insensitive search " ^ (btos conf.icase))

  | 'p' ->
      conf.preload <- not conf.preload;
      gotoy state.y;
      TEdone ("preload " ^ (btos conf.preload))

  | 'v' ->
      conf.verbose <- not conf.verbose;
      TEdone ("verbose " ^ (btos conf.verbose))

  | 'h' ->
      conf.maxhfit <- not conf.maxhfit;
      state.maxy <- state.maxy + (if conf.maxhfit then -state.h else state.h);
      TEdone ("maxhfit " ^ (btos conf.maxhfit))

  | 'c' ->
      conf.crophack <- not conf.crophack;
      TEdone ("crophack " ^ btos conf.crophack)

  | 'a' ->
      conf.showall <- not conf.showall;
      TEdone ("showall " ^ btos conf.showall)

  | 'f' ->
      conf.underinfo <- not conf.underinfo;
      TEdone ("underinfo " ^ btos conf.underinfo)

  | 'S' ->
      let ondone s =
        try
          conf.interpagespace <- int_of_string s;
          let rely = yratio state.y in
          state.maxy <- calcheight ();
          gotoy (truncate (float state.maxy *. rely));
        with exc ->
          state.text <- Printf.sprintf "bad integer `%s': %s"
            s (Printexc.to_string exc)
      in
      TEswitch ('%', "", None, intentry, ondone)

  | _ ->
      state.text <- Printf.sprintf "bad option %d `%c'" key c;
      TEstop
;;

let maxoutlinerows () = (state.h - 31) / 16;;

let enterselector allowdel outlines errmsg =
  if Array.length outlines = 0
  then (
    showtext ' ' errmsg;
  )
  else (
    Glut.setCursor Glut.CURSOR_INHERIT;
    let pageno =
      match state.layout with
      | [] -> -1
      | {pageno=pageno} :: rest -> pageno
    in
    let active =
      let rec loop n =
        if n = Array.length outlines
        then 0
        else
          let (_, _, outlinepageno, _) = outlines.(n) in
          if outlinepageno >= pageno then n else loop (n+1)
      in
      loop 0
    in
    state.outline <-
      Some (allowdel, active,
           max 0 ((active - maxoutlinerows () / 2)), outlines, "");
    Glut.postRedisplay ();
  )
;;

let enteroutlinemode () =
  let outlines =
    match state.outlines with
    | Oarray a -> a
    | Olist l ->
        let a = Array.of_list (List.rev l) in
        state.outlines <- Oarray a;
        a
    | Onarrow (a, b) -> a
  in
  enterselector false outlines "Document has no outline";
;;

let enterbookmarkmode () =
  let bookmarks = Array.of_list state.bookmarks in
  enterselector true bookmarks "Document has no bookmarks (yet)";
;;


let quickbookmark ?title () =
  match state.layout with
  | [] -> ()
  | l :: _ ->
      let title =
        match title with
        | None ->
            let sec = Unix.gettimeofday () in
            let tm = Unix.localtime sec in
            Printf.sprintf "Quick %d visited (%d/%d/%d %d:%d)"
              l.pageno
              tm.Unix.tm_mday
              tm.Unix.tm_mon
              (tm.Unix.tm_year + 1900)
              tm.Unix.tm_hour
              tm.Unix.tm_min
        | Some title -> title
      in
      state.bookmarks <-
        (title, 0, l.pageno, float l.pagey /. float l.pageh) :: state.bookmarks
;;

let doreshape w h =
  state.fullscreen <- None;
  Glut.reshapeWindow w h;
;;

let opendoc path password =
  invalidate ();
  state.path <- path;
  state.password <- password;
  Hashtbl.clear state.pagemap;

  writecmd state.csock ("open " ^ path ^ "\000" ^ password ^ "\000");
  Glut.setWindowTitle ("llpp " ^ Filename.basename path);
  wcmd "geometry" [`i state.w; `i state.h];
;;

let viewkeyboard ~key ~x ~y =
  let enttext te =
    state.textentry <- te;
    state.text <- "";
    enttext ();
    Glut.postRedisplay ()
  in
  match state.textentry with
  | None ->
      let c = Char.chr key in
      begin match c with
      | '\027' | 'q' ->
          exit 0

      | '\008' ->
          let y = getnav () in
          gotoy y

      | 'o' ->
          enteroutlinemode ()

      | 'u' ->
          state.rects <- [];
          state.text <- "";
          Glut.postRedisplay ()

      | '/' | '?' ->
          let ondone isforw s =
            cbput state.hists.pat s;
            cbrfollowlen state.hists.pat;
            state.searchpattern <- s;
            search s isforw
          in
          enttext (Some (c, "", Some (onhist state.hists.pat),
                        textentry, ondone (c ='/')))

      | '+' ->
          if Glut.getModifiers () land Glut.active_ctrl != 0
          then (
            let margin = max 0 (conf.margin - 1) in
            conf.margin <- margin;
            reshape state.winw state.h;
          )
          else
          let ondone s =
            let n =
              try int_of_string s with exc ->
                state.text <- Printf.sprintf "bad integer `%s': %s"
                  s (Printexc.to_string exc);
                max_int
            in
            if n != max_int
            then (
              conf.pagebias <- n;
              state.text <- "page bias is now " ^ string_of_int n;
            )
          in
          enttext (Some ('+', "", None, intentry, ondone))

      | '-' ->
          if Glut.getModifiers () land Glut.active_ctrl != 0
          then (
            let margin = min 8 (conf.margin + 1) in
            conf.margin <- margin;
            reshape state.winw state.h;
          )
          else
          let ondone msg =
            state.text <- msg;
          in
          enttext (Some ('-', "", None, optentry, ondone))

      | '0' .. '9' ->
          let ondone s =
            let n =
              try int_of_string s with exc ->
                state.text <- Printf.sprintf "bad integer `%s': %s"
                  s (Printexc.to_string exc);
                -1
            in
            if n >= 0
            then (
              addnav ();
              cbput state.hists.pag (string_of_int n);
              cbrfollowlen state.hists.pag;
              gotoy (getpagey (n + conf.pagebias - 1))
            )
          in
          let pageentry text key =
            match Char.unsafe_chr key with
            | 'g' -> TEdone text
            | _ -> intentry text key
          in
          let text = "x" in text.[0] <- c;
          enttext (Some (':', text, Some (onhist state.hists.pag),
                        pageentry, ondone))

      | 'b' ->
          conf.scrollw <- if conf.scrollw > 0 then 0 else 5;
          reshape state.winw state.h;

      | 'l' ->
          conf.hlinks <- not conf.hlinks;
          state.text <- "highlightlinks " ^ if conf.hlinks then "on" else "off";
          Glut.postRedisplay ()

      | 'a' ->
          conf.autoscroll <- not conf.autoscroll

      | 'P' ->
          conf.presentation <- not conf.presentation;
          represent ()

      | 'f' ->
          begin match state.fullscreen with
          | None ->
              state.fullscreen <- Some (state.w, state.h);
              Glut.fullScreen ()
          | Some (w, h) ->
              state.fullscreen <- None;
              doreshape w h
          end

      | 'g' ->
          gotoy 0

      | 'n' ->
          search state.searchpattern true

      | 'p' | 'N' ->
          search state.searchpattern false

      | 't' ->
          begin match state.layout with
          | [] -> ()
          | l :: _ ->
              gotoy (getpagey l.pageno - conf.interpagespace)
          end

      | ' ' ->
          begin match List.rev state.layout with
          | [] -> ()
          | l :: _ ->
              gotoy (clamp (l.pageh - l.pagey + conf.interpagespace))
          end

      | '\127' ->
          begin match state.layout with
          | [] -> ()
          | l :: _ ->
              gotoy (clamp (-l.pageh - conf.interpagespace));
          end

      | '=' ->
          let f (fn, ln) l =
            if fn = -1 then l.pageno, l.pageno else fn, l.pageno
          in
          let fn, ln = List.fold_left f (-1, -1) state.layout in
          let s =
            let maxy = state.maxy - (if conf.maxhfit then state.h else 0) in
            let percent =
              if maxy <= 0
              then 100.
              else (100. *. (float state.y /. float maxy)) in
            if fn = ln
            then
              Printf.sprintf "Page %d of %d %.2f%%"
                (fn+1) state.pagecount percent
            else
              Printf.sprintf
                "Pages %d-%d of %d %.2f%%"
                (fn+1) (ln+1) state.pagecount percent
          in
          showtext ' ' s;

      | 'w' ->
          begin match state.layout with
          | [] -> ()
          | l :: _ ->
              doreshape l.pagew l.pageh;
              Glut.postRedisplay ();
          end

      | '\'' ->
          enterbookmarkmode ()

      | 'm' ->
          let ondone s =
            match state.layout with
            | l :: _ ->
                state.bookmarks <-
                  (s, 0, l.pageno, float l.pagey /. float l.pageh)
                :: state.bookmarks
            | _ -> ()
          in
          enttext (Some ('~', "", None, textentry, ondone))

      | '~' ->
          quickbookmark ();
          showtext ' ' "Quick bookmark added";

      | 'z' ->
          begin match state.layout with
          | l :: _ ->
              let a = getpagewh l.pagedimno in
              let w, h =
                if conf.crophack
                then
                  (truncate (1.8 *. (a.(1) -. a.(0))),
                  truncate (1.2 *. (a.(3) -. a.(0))))
                else
                  (truncate (a.(1) -. a.(0)),
                  truncate (a.(3) -. a.(0)))
              in
              doreshape w h;
              Glut.postRedisplay ();

          | [] -> ()
          end

      | '<' | '>' ->
          rotate (state.rotate + (if c = '>' then 30 else -30));

      | '[' | ']' ->
          state.colorscale <-
            max 0.0
            (min (state.colorscale +. (if c = ']' then 0.1 else -0.1)) 1.0);
          Glut.postRedisplay ()

      | 'k' -> gotoy (clamp (-conf.scrollincr))
      | 'j' -> gotoy (clamp conf.scrollincr)

      | 'r' -> opendoc state.path state.password

      | _ ->
          vlog "huh? %d %c" key (Char.chr key);
      end

  | Some (c, text, onhist, onkey, ondone) when key = 8 ->
      let len = String.length text in
      if len = 0
      then (
        state.textentry <- None;
        Glut.postRedisplay ();
      )
      else (
        let s = String.sub text 0 (len - 1) in
        enttext (Some (c, s, onhist, onkey, ondone))
      )

  | Some (c, text, onhist, onkey, ondone) ->
      begin match Char.unsafe_chr key with
      | '\r' | '\n' ->
          ondone text;
          state.textentry <- None;
          Glut.postRedisplay ()

      | '\027' ->
          state.textentry <- None;
          Glut.postRedisplay ()

      | _ ->
          begin match onkey text key with
          | TEdone text ->
              state.textentry <- None;
              ondone text;
              Glut.postRedisplay ()

          | TEcont text ->
              enttext (Some (c, text, onhist, onkey, ondone));

          | TEstop ->
              state.textentry <- None;
              Glut.postRedisplay ()

          | TEswitch te ->
              state.textentry <- Some te;
              Glut.postRedisplay ()
          end;
      end;
;;

let narrow outlines pattern =
  let reopt = try Some (Str.regexp_case_fold pattern) with _ -> None in
  match reopt with
  | None -> None
  | Some re ->
      let rec fold accu n =
        if n = -1
        then accu
        else
          let (s, _, _, _) as o = outlines.(n) in
          let accu =
            if (try ignore (Str.search_forward re s 0); true
              with Not_found -> false)
            then (o :: accu)
            else accu
          in
          fold accu (n-1)
      in
      let matched = fold [] (Array.length outlines - 1) in
      if matched = [] then None else Some (Array.of_list matched)
;;

let outlinekeyboard ~key ~x ~y (allowdel, active, first, outlines, qsearch) =
  let search active pattern incr =
    let dosearch re =
      let rec loop n =
        if n = Array.length outlines || n = -1
        then None
        else
          let (s, _, _, _) = outlines.(n) in
          if
            (try ignore (Str.search_forward re s 0); true
              with Not_found -> false)
          then Some n
          else loop (n + incr)
      in
      loop active
    in
    try
      let re = Str.regexp_case_fold pattern in
      dosearch re
    with Failure s ->
      state.text <- s;
      None
  in
  let firstof active = max 0 (active - maxoutlinerows () / 2) in
  match key with
  | 27 ->
      if String.length qsearch = 0
      then (
        state.text <- "";
        state.outline <- None;
        Glut.postRedisplay ();
      )
      else (
        state.text <- "";
        state.outline <- Some (allowdel, active, first, outlines, "");
        Glut.postRedisplay ();
      )

  | 18 | 19 ->
      let incr = if key = 18 then -1 else 1 in
      let active, first =
        match search (active + incr) qsearch incr with
        | None ->
            state.text <- qsearch ^ " [not found]";
            active, first
        | Some active ->
            state.text <- qsearch;
            active, firstof active
      in
      state.outline <- Some (allowdel, active, first, outlines, qsearch);
      Glut.postRedisplay ();

  | 8 ->
      let len = String.length qsearch in
      if len = 0
      then ()
      else (
        if len = 1
        then (
          state.text <- "";
          state.outline <- Some (allowdel, active, first, outlines, "");
        )
        else
          let qsearch = String.sub qsearch 0 (len - 1) in
          let active, first =
            match search active qsearch ~-1 with
            | None ->
                state.text <- qsearch ^ " [not found]";
                active, first
            | Some active ->
                state.text <- qsearch;
                active, firstof active
          in
          state.outline <- Some (allowdel, active, first, outlines, qsearch);
      );
      Glut.postRedisplay ()

  | 13 ->
      if active < Array.length outlines
      then (
        let (_, _, n, t) = outlines.(active) in
        gotopage n t;
      );
      state.text <- "";
      if allowdel then state.bookmarks <- Array.to_list outlines;
      state.outline <- None;
      Glut.postRedisplay ();

  | _ when key >= 32 && key < 127 ->
      let pattern = addchar qsearch (Char.chr key) in
      let active, first =
        match search active pattern 1 with
        | None ->
            state.text <- pattern ^ " [not found]";
            active, first
        | Some active ->
            state.text <- pattern;
            active, firstof active
      in
      state.outline <- Some (allowdel, active, first, outlines, pattern);
      Glut.postRedisplay ()

  | 14 when not allowdel ->
      let optoutlines = narrow outlines qsearch in
      begin match optoutlines with
      | None -> state.text <- "can't narrow"
      | Some outlines ->
          state.outline <- Some (allowdel, 0, 0, outlines, qsearch);
          match state.outlines with
          | Olist l -> ()
          | Oarray a -> state.outlines <- Onarrow (outlines, a)
          | Onarrow (a, b) -> state.outlines <- Onarrow (outlines, b)
      end;
      Glut.postRedisplay ()

  | 21 when not allowdel ->
      let outline =
        match state.outlines with
        | Oarray a -> a
        | Olist l ->
            let a = Array.of_list (List.rev l) in
            state.outlines <- Oarray a;
            a
        | Onarrow (a, b) ->
            state.outlines <- Oarray b;
            b
      in
      state.outline <- Some (allowdel, 0, 0, outline, qsearch);
      Glut.postRedisplay ()

  | 12 ->
      state.outline <-
        Some (allowdel, active, firstof active, outlines, qsearch);
      Glut.postRedisplay ()

  | 127 when allowdel ->
      let len = Array.length outlines - 1 in
      if len = 0
      then (
        state.outline <- None;
        state.bookmarks <- [];
      )
      else (
        let bookmarks = Array.init len
          (fun i ->
            let i = if i >= active then i + 1 else i in
            outlines.(i)
          )
        in
        state.outline <-
          Some (allowdel,
               min active (len-1),
               min first (len-1),
               bookmarks, qsearch)
        ;
      );
      Glut.postRedisplay ()

  | _ -> log "unknown key %d" key
;;

let keyboard ~key ~x ~y =
  if key = 7
  then
    wcmd "interrupt" []
  else
    match state.outline with
    | None -> viewkeyboard ~key ~x ~y
    | Some outline -> outlinekeyboard ~key ~x ~y outline
;;

let special ~key ~x ~y =
  match state.outline with
  | None ->
      begin match state.textentry with
      | None ->
          let y =
            match key with
            | Glut.KEY_F3        -> search state.searchpattern true; state.y
            | Glut.KEY_UP        -> clamp (-conf.scrollincr)
            | Glut.KEY_DOWN      -> clamp conf.scrollincr
            | Glut.KEY_PAGE_UP   ->
                if Glut.getModifiers () land Glut.active_ctrl != 0
                then
                  match state.layout with
                  | [] -> state.y
                  | l :: _ -> state.y - l.pagey
                else
                  clamp (-state.h)
            | Glut.KEY_PAGE_DOWN ->
                if Glut.getModifiers () land Glut.active_ctrl != 0
                then
                  match List.rev state.layout with
                  | [] -> state.y
                  | l :: _ -> getpagey l.pageno
                else
                  clamp state.h
            | Glut.KEY_HOME -> addnav (); 0
            | Glut.KEY_END ->
                addnav ();
                state.maxy - (if conf.maxhfit then state.h else 0)
            | _ -> state.y
          in
          if not conf.verbose then state.text <- "";
          gotoy y

      | Some (c, s, Some onhist, onkey, ondone) ->
          let s =
            match key with
            | Glut.KEY_UP    -> onhist HCprev
            | Glut.KEY_DOWN  -> onhist HCnext
            | Glut.KEY_HOME  -> onhist HCfirst
            | Glut.KEY_END   -> onhist HClast
            | _ -> state.text
          in
          state.textentry <- Some (c, s, Some onhist, onkey, ondone);
          Glut.postRedisplay ()

      | _ -> ()
      end

  | Some (allowdel, active, first, outlines, qsearch) ->
      let maxrows = maxoutlinerows () in
      let navigate incr =
        let active = active + incr in
        let active = max 0 (min active (Array.length outlines - 1)) in
        let first =
          if active > first
          then
            let rows = active - first in
            if rows > maxrows then active - maxrows else first
          else active
        in
        state.outline <- Some (allowdel, active, first, outlines, qsearch);
        Glut.postRedisplay ()
      in
      match key with
      | Glut.KEY_UP        -> navigate ~-1
      | Glut.KEY_DOWN      -> navigate   1
      | Glut.KEY_PAGE_UP   -> navigate ~-maxrows
      | Glut.KEY_PAGE_DOWN -> navigate   maxrows

      | Glut.KEY_HOME ->
          state.outline <- Some (allowdel, 0, 0, outlines, qsearch);
          Glut.postRedisplay ()

      | Glut.KEY_END ->
          let active = Array.length outlines - 1 in
          let first = max 0 (active - maxrows) in
          state.outline <- Some (allowdel, active, first, outlines, qsearch);
          Glut.postRedisplay ()

      | _ -> ()
;;

let drawplaceholder l =
  GlDraw.color (scalecolor 1.0);
  GlDraw.rect
    (0.0, float l.pagedispy)
    (float l.pagew, float (l.pagedispy + l.pagevh))
  ;
  let x = 0.0
  and y = float (l.pagedispy + 13) in
  let font = Glut.BITMAP_8_BY_13 in
  GlDraw.color (0.0, 0.0, 0.0);
  GlPix.raster_pos ~x ~y ();
  String.iter (fun c -> Glut.bitmapCharacter ~font ~c:(Char.code c))
    ("Loading " ^ string_of_int l.pageno);
;;

let now () = Unix.gettimeofday ();;

let drawpage i l =
  begin match getopaque l.pageno with
  | Some opaque when validopaque opaque ->
      if state.textentry = None
      then GlDraw.color (scalecolor 1.0)
      else GlDraw.color (scalecolor 0.4);
      let a = now () in
      draw (l.pagedispy, l.pagew, l.pagevh, l.pagey, conf.hlinks)
        opaque;
      let b = now () in
      let d = b-.a in
      vlog "draw %f sec" d;

  | _ ->
      drawplaceholder l;
  end;
  l.pagedispy + l.pagevh;
;;

let scrollindicator () =
  let maxy = state.maxy - (if conf.maxhfit then state.h else 0) in
  GlDraw.color (0.64 , 0.64, 0.64);
  GlDraw.rect
    (0., 0.)
    (float conf.scrollw, float state.h)
  ;
  GlDraw.color (0.0, 0.0, 0.0);
  let sh = (float (maxy + state.h) /. float state.h)  in
  let sh = float state.h /. sh in
  let sh = max sh (float conf.scrollh) in

  let percent =
    if state.y = state.maxy
    then 1.0
    else float state.y /. float maxy
  in
  let position = (float state.h -. sh) *. percent in

  let position =
    if position +. sh > float state.h
    then
      float state.h -. sh
    else
      position
  in
  GlDraw.rect
    (0.0, position)
    (float conf.scrollw, position +. sh)
  ;
;;

let showsel margin =
  match state.mstate with
  | Mnone ->
      ()

  | Msel ((x0, y0), (x1, y1)) ->
      let rec loop = function
        | l :: ls ->
            if (y0 >= l.pagedispy && y0 <= (l.pagedispy + l.pagevh))
              || ((y1 >= l.pagedispy && y1 <= (l.pagedispy + l.pagevh)))
            then
              match getopaque l.pageno with
              | Some opaque when validopaque opaque ->
                  let oy = -l.pagey + l.pagedispy in
                  seltext opaque (x0 - margin, y0, x1 - margin, y1) oy;
                  ()
              | _ -> ()
            else loop ls
        | [] -> ()
      in
      loop state.layout
;;

let showrects () =
  Gl.enable `blend;
  GlDraw.color (0.0, 0.0, 1.0) ~alpha:0.5;
  GlFunc.blend_func `src_alpha `one_minus_src_alpha;
  List.iter
    (fun (pageno, c, (x0, y0, x1, y1, x2, y2, x3, y3)) ->
      List.iter (fun l ->
        if l.pageno = pageno
        then (
          let d = float (l.pagedispy - l.pagey) in
          GlDraw.color (0.0, 0.0, 1.0 /. float c) ~alpha:0.5;
          GlDraw.begins `quads;
          (
            GlDraw.vertex2 (x0, y0+.d);
            GlDraw.vertex2 (x1, y1+.d);
            GlDraw.vertex2 (x2, y2+.d);
            GlDraw.vertex2 (x3, y3+.d);
          );
          GlDraw.ends ();
        )
      ) state.layout
    ) state.rects
  ;
  Gl.disable `blend;
;;

let showoutline = function
  | None -> ()
  | Some (allowdel, active, first, outlines, qsearch) ->
      Gl.enable `blend;
      GlFunc.blend_func `src_alpha `one_minus_src_alpha;
      GlDraw.color (0., 0., 0.) ~alpha:0.85;
      GlDraw.rect (0., 0.) (float state.w, float state.h);
      Gl.disable `blend;

      GlDraw.color (1., 1., 1.);
      let font = Glut.BITMAP_9_BY_15 in
      let draw_string x y s =
        GlPix.raster_pos ~x ~y ();
        String.iter (fun c -> Glut.bitmapCharacter ~font ~c:(Char.code c)) s
      in
      let rec loop row =
        if row = Array.length outlines || (row - first) * 16 > state.h
        then ()
        else (
          let (s, l, _, _) = outlines.(row) in
          let y = (row - first) * 16 in
          let x = 5 + 15*l in
          if row = active
          then (
            Gl.enable `blend;
            GlDraw.polygon_mode `both `line;
            GlFunc.blend_func `src_alpha `one_minus_src_alpha;
            GlDraw.color (1., 1., 1.) ~alpha:0.9;
            GlDraw.rect (0., float (y + 1))
              (float (state.winw - conf.scrollw - 1), float (y + 18));
            GlDraw.polygon_mode `both `fill;
            Gl.disable `blend;
            GlDraw.color (1., 1., 1.);
          );
          draw_string (float x) (float (y + 16)) s;
          loop (row+1)
        )
      in
      loop first
;;

let display () =
  let margin = (state.winw - (state.w + conf.scrollw)) / 2 in
  GlDraw.viewport margin 0 state.w state.h;
  GlClear.color (scalecolor 0.5);
  GlClear.clear [`color];
  let lasty = List.fold_left drawpage 0 (state.layout) in
  showrects ();
  GlDraw.viewport (state.winw - conf.scrollw) 0 state.winw state.h;
  scrollindicator ();
  showsel margin;
  GlDraw.viewport 0 0 state.winw state.h;
  showoutline state.outline;
  enttext ();
  Glut.swapBuffers ();
;;

let getunder x y =
  let margin = (state.winw - (state.w + conf.scrollw)) / 2 in
  let x = x - margin in
  let rec f = function
    | l :: rest ->
        begin match getopaque l.pageno with
        | Some opaque when validopaque opaque ->
            let y = y - l.pagedispy in
            if y > 0
            then
              let y = l.pagey + y in
              match whatsunder opaque x y with
              | Unone -> f rest
              | under -> under
            else
              f rest
        | _ ->
            f rest
        end
    | [] -> Unone
  in
  f state.layout
;;

let mouse ~button ~bstate ~x ~y =
  match button with
  | Glut.OTHER_BUTTON n when (n == 3 || n == 4) && bstate = Glut.UP ->
      let incr =
        if n = 3
        then
          -conf.scrollincr
        else
          conf.scrollincr
      in
      let incr = incr * 2 in
      let y = clamp incr in
      gotoy y

  | Glut.LEFT_BUTTON when state.outline = None ->
      let dest = if bstate = Glut.DOWN then getunder x y else Unone in
      begin match dest with
      | Ulinkgoto (pageno, top) ->
          if pageno >= 0
          then
            gotopage1 pageno top

      | Ulinkuri s ->
          print_endline s

      | Unone when bstate = Glut.DOWN ->
          Glut.setCursor Glut.CURSOR_INHERIT;
          state.mstate <- Mnone

      | Unone | Utext _ ->
          if bstate = Glut.DOWN
          then (
            if state.rotate mod 360 = 0
            then (
              state.mstate <- Msel ((x, y), (x, y));
              Glut.postRedisplay ()
            )
          )
          else (
            match state.mstate with
            | Mnone -> ()
            | Msel ((x0, y0), (x1, y1)) ->
                let f l =
                  if (y0 >= l.pagedispy && y0 <= (l.pagedispy + l.pagevh))
                    || ((y1 >= l.pagedispy && y1 <= (l.pagedispy + l.pagevh)))
                  then
                      match getopaque l.pageno with
                      | Some opaque when validopaque opaque ->
                          copysel opaque
                      | _ -> ()
                in
                List.iter f state.layout;
                copysel "";             (* ugly *)
                Glut.setCursor Glut.CURSOR_INHERIT;
                state.mstate <- Mnone;
          )
      end

  | _ ->
      ()
;;
let mouse ~button ~state ~x ~y = mouse button state x y;;

let motion ~x ~y =
  if state.outline = None
  then
    match state.mstate with
    | Mnone -> ()
    | Msel (a, _) ->
        state.mstate <- Msel (a, (x, y));
        Glut.postRedisplay ()
;;

let pmotion ~x ~y =
  if state.outline = None
  then
    match state.mstate with
    | Mnone ->
        begin match getunder x y with
        | Unone -> Glut.setCursor Glut.CURSOR_INHERIT
        | Ulinkuri uri ->
            if conf.underinfo then showtext 'u' ("ri: " ^ uri);
            Glut.setCursor Glut.CURSOR_INFO
        | Ulinkgoto (page, y) ->
            if conf.underinfo then showtext 'p' ("age: " ^ string_of_int page);
            Glut.setCursor Glut.CURSOR_INFO
        | Utext s ->
            if conf.underinfo then showtext 'f' ("ont: " ^ s);
            Glut.setCursor Glut.CURSOR_TEXT
        end

    | Msel (a, _) ->
        ()
;;

let () =
  let statepath =
    let home =
      if Sys.os_type = "Win32"
      then
        try Sys.getenv "HOMEPATH" with Not_found -> ""
      else
        try Filename.concat (Sys.getenv "HOME") ".config" with Not_found -> ""
    in
    Filename.concat home "llpp"
  in
  let pstate =
    try
      let ic = open_in_bin statepath in
      let hash = input_value ic in
      close_in ic;
      hash
    with exn ->
      if false
      then
        prerr_endline ("Error loading state " ^ Printexc.to_string exn)
      ;
      Hashtbl.create 1
  in
  let savestate () =
    try
      let w, h =
        match state.fullscreen with
        | None -> state.winw, state.h
        | Some wh -> wh
      in
      Hashtbl.replace pstate state.path (state.bookmarks, w, h);
      let oc = open_out_bin statepath in
      output_value oc pstate
    with exn ->
      if false
      then
        prerr_endline ("Error saving state " ^ Printexc.to_string exn)
      ;
  in
  let setstate () =
    try
      let statebookmarks, statew, stateh = Hashtbl.find pstate state.path in
      state.w <- statew;
      state.h <- stateh;
      state.bookmarks <- statebookmarks;
    with Not_found -> ()
    | exn ->
      prerr_endline ("Error setting state " ^ Printexc.to_string exn)
  in

  Arg.parse
    ["-p", Arg.String (fun s -> state.password <- s) , "password"]
    (fun s -> state.path <- s)
    ("Usage: " ^ Sys.argv.(0) ^ " [options] some.pdf\noptions:")
  ;
  let name =
    if String.length state.path = 0
    then (prerr_endline "filename missing"; exit 1)
    else state.path
  in

  setstate ();
  let _ = Glut.init Sys.argv in
  let () = Glut.initDisplayMode ~depth:false ~double_buffer:true () in
  let () = Glut.initWindowSize state.w state.h in
  let _ = Glut.createWindow ("llpp " ^ Filename.basename name) in

  let csock, ssock =
    if Sys.os_type = "Unix"
    then
      Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0
    else
      let addr = Unix.ADDR_INET (Unix.inet_addr_loopback, 1337) in
      let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      Unix.setsockopt sock Unix.SO_REUSEADDR true;
      Unix.bind sock addr;
      Unix.listen sock 1;
      let csock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      Unix.connect csock addr;
      let ssock, _ = Unix.accept sock in
      Unix.close sock;
      let opts sock =
        Unix.setsockopt sock Unix.TCP_NODELAY true;
        Unix.setsockopt_optint sock Unix.SO_LINGER None;
      in
      opts ssock;
      opts csock;
      at_exit (fun () -> Unix.shutdown ssock Unix.SHUTDOWN_ALL);
      ssock, csock
  in

  let () = Glut.displayFunc display in
  let () = Glut.reshapeFunc reshape in
  let () = Glut.keyboardFunc keyboard in
  let () = Glut.specialFunc special in
  let () = Glut.idleFunc (Some idle) in
  let () = Glut.mouseFunc mouse in
  let () = Glut.motionFunc motion in
  let () = Glut.passiveMotionFunc pmotion in

  init ssock;
  state.csock <- csock;
  state.ssock <- ssock;
  state.text <- "Opening " ^ name;
  writecmd state.csock ("open " ^ state.path ^ "\000" ^ state.password ^ "\000");

  at_exit savestate;

  let rec handlelablglutbug () =
    try
      Glut.mainLoop ();
    with Glut.BadEnum "key in special_of_int" ->
      showtext '!' " LablGlut bug: special key not recognized";
      handlelablglutbug ()
  in
  handlelablglutbug ();
;;
