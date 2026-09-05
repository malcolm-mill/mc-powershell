# Colour scheme, 256-colour palette indices. Mirrors the classic mc "default" skin.
# Kept as data so a future skin loader can just swap this hashtable.

$script:McTheme = @{
    PanelBg       = 4      # blue
    FileFg        = 7      # light grey
    DirFg         = 15     # bright white
    ExecFg        = 10     # bright green
    LinkFg        = 14     # bright cyan
    MarkedFg      = 11     # yellow

    BorderFg      = 7
    BorderActive  = 15

    TitleFg       = 0
    TitleBg       = 6      # black on cyan for the active panel path
    TitleInactive = 15

    HeaderFg      = 14     # column headers

    CursorFg      = 0
    CursorBg      = 6      # black on cyan
    CursorFgIdle  = 15
    CursorBgIdle  = 8      # dim highlight on the inactive panel

    StatusFg      = 15

    ModeRoFg      = 0      # read-only badge: black on green, calm
    ModeRoBg      = 10
    ModeRwFg      = 15     # read-write badge: white on red, alarming
    ModeRwBg      = 9

    CmdFg         = 7
    CmdBg         = 0

    MenuFg        = 15     # menu bar, mc keeps it on the panel blue
    MenuBg        = 4
    MenuSelFg     = 0      # the open menu's title
    MenuSelBg     = 6
    MenuHotFg     = 11     # the hotkey letter

    ViewFg        = 7
    ViewBg        = 0
    ViewLineNoFg  = 8
    ViewMatchFg   = 0
    ViewMatchBg   = 11

    KeyNumFg      = 7      # "1" in "1Help"
    KeyNumBg      = 0
    KeyLabelFg    = 0      # "Help" in "1Help"
    KeyLabelBg    = 6

    DialogFg      = 0
    DialogBg      = 7      # grey dialog, mc style
    DialogTitleFg = 0
    DialogTitleBg = 6
}

# Attribute bits understood by Mc.Native.Screen
$script:AttrNone      = [byte]0
$script:AttrBold      = [byte]1
$script:AttrReverse   = [byte]2
$script:AttrUnderline = [byte]4
