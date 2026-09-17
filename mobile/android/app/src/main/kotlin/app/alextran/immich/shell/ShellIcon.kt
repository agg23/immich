package app.alextran.immich.shell

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.DocumentScanner
import androidx.compose.material.icons.outlined.TextSnippet
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.PhotoAlbum
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.SpaceDashboard
import androidx.compose.material.icons.rounded.Abc
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.AddPhotoAlternate
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.DeleteForever
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.ImageSearch
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PersonAdd
import androidx.compose.material.icons.rounded.PersonRemove
import androidx.compose.material.icons.rounded.PhotoAlbum
import androidx.compose.material.icons.rounded.PhotoLibrary
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Restore
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Slideshow
import androidx.compose.material.icons.rounded.Sort
import androidx.compose.material.icons.rounded.SpaceDashboard
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * The only place that knows what Dart's icon tokens look like on Android.
 *
 * Glyphs follow the Flutter app's own choices so nothing changes when the native chrome takes
 * over. `filled` is the selected-state variant a [androidx.compose.material3.NavigationBar] wants.
 */
enum class ShellIcon(val token: String, val image: ImageVector, val filled: ImageVector = image) {
  ADD("add", Icons.Rounded.Add),
  ADD_PHOTO("addPhoto", Icons.Rounded.AddPhotoAlternate),
  ADD_USER("addUser", Icons.Rounded.PersonAdd),
  ALBUMS("albums", Icons.Outlined.PhotoAlbum, Icons.Rounded.PhotoAlbum),
  CLOSE("close", Icons.Rounded.Close),
  COMMENT("comment", Icons.Outlined.ChatBubbleOutline),
  DELETE("delete", Icons.Rounded.Delete),
  DELETE_FOREVER("deleteForever", Icons.Rounded.DeleteForever),
  EDIT("edit", Icons.Rounded.Edit),
  FAVORITE("favorite", Icons.Outlined.FavoriteBorder),
  FAVORITE_FILLED("favoriteFilled", Icons.Rounded.Favorite),
  LIBRARY("library", Icons.Outlined.SpaceDashboard, Icons.Rounded.SpaceDashboard),
  LINK("link", Icons.Rounded.Link),
  // Vertical: the horizontal ellipsis is iOS's overflow, not Android's.
  OVERFLOW("overflow", Icons.Rounded.MoreVert),
  PAUSE("pause", Icons.Rounded.Pause),
  PHOTOS("photos", Icons.Outlined.PhotoLibrary, Icons.Rounded.PhotoLibrary),
  PLAY("play", Icons.Rounded.PlayArrow),
  REMOVE_USER("removeUser", Icons.Rounded.PersonRemove),
  RESTORE("restore", Icons.Rounded.Restore),
  SEARCH("search", Icons.Rounded.Search),
  SEARCH_DESCRIPTION("searchDescription", Icons.Outlined.TextSnippet),
  SEARCH_FILENAME("searchFilename", Icons.Rounded.Abc),
  SEARCH_OCR("searchOcr", Icons.Outlined.DocumentScanner),
  SEARCH_SMART("searchSmart", Icons.Rounded.ImageSearch),
  SETTINGS("settings", Icons.Rounded.Settings),
  SLIDESHOW("slideshow", Icons.Rounded.Slideshow),
  SORT("sort", Icons.Rounded.Sort);

  companion object {
    private val byToken = entries.associateBy { it.token }

    /** Dart may be newer than the app it is talking to, so an unknown token is expected. */
    fun from(token: Any?): ShellIcon? {
      val raw = token as? String ?: return null
      return byToken[raw] ?: run {
        shellLog("[shell:nav] unknown icon token $raw")
        null
      }
    }
  }
}
