package app.alextran.immich.shell

/** One tab, as Dart declared it; only the artwork is decided on this side. */
data class ShellTab(
  val id: String,
  val label: String,
  val icon: ShellIcon?,
  /** Android has no tab-bar affordance for search, so this only changes the tab's own screen. */
  val isSearch: Boolean,
) {
  companion object {
    fun from(raw: Map<*, *>): ShellTab? {
      val id = raw["id"] as? String ?: return null
      return ShellTab(
        id = id,
        label = raw["label"] as? String ?: id,
        icon = ShellIcon.from(raw["icon"]),
        isSearch = raw["role"] == "search",
      )
    }
  }
}
