package app.alextran.immich.shell

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BrokenImage
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.runtime.withFrameNanos
import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale
import kotlin.math.roundToInt

/**
 * What the viewer needs to know about the grid beneath it: where a tile is, how big tiles are,
 * and how to bring one on screen for the return flight. Plain state; the grid keeps it current.
 */
class TimelineGridState {
  /** Bounds in root coordinates of every tile currently laid out, by flat index. */
  val tileBounds = HashMap<Int, Rect>()
  var tilePx = 0
  var scrollToTop: (suspend () -> Unit)? = null
  var reveal: (suspend (Int) -> Unit)? = null

  /** A tile the viewer's flying image is standing in for. */
  var hiddenIndex by mutableIntStateOf(-1)
}

/** The Photos tab: a Material top bar that leaves on scroll over the native grid. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NativeTimelineRoot(stack: TabStack, source: TimelineSource) {
  val scrollBehavior = TopAppBarDefaults.enterAlwaysScrollBehavior()
  val bar = stack.rootBar
  val density = LocalDensity.current
  val bottom = with(density) { maxOf(stack.root.bottomChromePx, WindowInsets.navigationBars.getBottom(density)).toDp() }

  LaunchedEffect(source) { source.open() }
  // No Flutter host here, but Dart still follows the tab so its stack is the one this tab mirrors.
  DisposableEffect(stack) {
    ShellEngine.nativeRootBecameVisible(stack.tab.id)
    onDispose {}
  }

  Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).nestedScroll(scrollBehavior.nestedScrollConnection)) {
    val title = bar?.title
    if (bar != null && title != null) {
      ShellTopBar(route = bar.name, title = title, actions = bar.actions, scrollBehavior = scrollBehavior)
    } else {
      TopAppBar(title = { Text(stack.tab.label) }, scrollBehavior = scrollBehavior)
    }
    TimelineGrid(source, stack.grid, bottomPadding = bottom) { index -> stack.openViewer(source.session, index) }
  }
}

private class GridLayout(val sections: List<TimelineSource.Section>, val source: TimelineSource) {
  /** Each section before a tile adds one header, and so does its own. */
  fun gridIndexOf(flat: Int) = flat + source.sectionIndex(flat) + 1

  fun flatOf(gridIndex: Int): Int {
    if (sections.isEmpty()) return 0
    var lo = 0
    var hi = sections.size - 1
    var found = 0
    while (lo <= hi) {
      val mid = (lo + hi) ushr 1
      if (sections[mid].offset + mid <= gridIndex) {
        found = mid
        lo = mid + 1
      } else {
        hi = mid - 1
      }
    }
    val header = sections[found].offset + found
    return if (gridIndex <= header) sections[found].offset else gridIndex - found - 1
  }
}

@Composable
fun TimelineGrid(
  source: TimelineSource,
  grid: TimelineGridState,
  bottomPadding: androidx.compose.ui.unit.Dp,
  modifier: Modifier = Modifier,
  onOpen: (Int) -> Unit,
) {
  val sections = source.sections
  val layout = remember(sections) { GridLayout(sections, source) }
  val state = rememberLazyGridState()
  val density = LocalDensity.current

  BoxWithConstraints(modifier.fillMaxSize()) {
    val spacingPx = with(density) { SPACING.roundToPx() }
    val minTilePx = with(density) { MIN_TILE.roundToPx() }
    val columns = maxOf(3, (constraints.maxWidth + spacingPx) / (minTilePx + spacingPx))
    val tilePx = (constraints.maxWidth - spacingPx * (columns - 1)) / columns
    grid.tilePx = tilePx

    grid.scrollToTop = { state.animateScrollToItem(0) }
    grid.reveal = { flat ->
      val index = layout.gridIndexOf(flat)
      val info = state.layoutInfo
      val onScreen = info.visibleItemsInfo.any {
        it.index == index && it.offset.y >= 0 && it.offset.y + it.size.height <= info.viewportEndOffset
      }
      if (!onScreen) {
        state.scrollToItem(index, scrollOffset = -(info.viewportSize.height - tilePx) / 2)
        // Laid out on the next frame; the caller reads the tile's bounds after that.
        withFrameNanos {}
        withFrameNanos {}
      }
    }
    DisposableEffect(grid) {
      onDispose {
        grid.tileBounds.clear()
        grid.scrollToTop = null
        grid.reveal = null
      }
    }

    LazyVerticalGrid(
      columns = GridCells.Fixed(columns),
      state = state,
      modifier = Modifier.fillMaxSize(),
      contentPadding = PaddingValues(bottom = bottomPadding),
      verticalArrangement = Arrangement.spacedBy(SPACING),
      horizontalArrangement = Arrangement.spacedBy(SPACING),
    ) {
      for ((s, section) in sections.withIndex()) {
        item(key = "h${section.offset}/$s", span = { GridItemSpan(maxLineSpan) }, contentType = "header") {
          DayHeader(section.date)
        }
        items(count = section.count, key = { "a${section.offset + it}" }, contentType = { "tile" }) { i ->
          TimelineTile(source, section.offset + i, tilePx, grid, onOpen)
        }
      }
    }

    TimelineScrubber(state, source, layout, bottomPadding, Modifier.align(Alignment.TopEnd))
  }
}

@Composable
private fun DayHeader(date: Long?) {
  Text(
    dayTitle(date),
    style = MaterialTheme.typography.titleMedium,
    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
  )
}

@Composable
private fun TimelineTile(source: TimelineSource, flat: Int, tilePx: Int, grid: TimelineGridState, onOpen: (Int) -> Unit) {
  val asset = source.asset(flat)
  val thumbnail = rememberThumbnailState(asset, tilePx)
  val bitmap = thumbnail.bitmap
  val image = remember(bitmap) { bitmap?.asImageBitmap() }
  val hidden = grid.hiddenIndex == flat
  DisposableEffect(flat) { onDispose { grid.tileBounds.remove(flat) } }
  Box(
    Modifier
      .aspectRatio(1f)
      .onGloballyPositioned { grid.tileBounds[flat] = it.boundsInRoot() }
      .graphicsLayer { alpha = if (hidden) 0f else 1f }
      .background(MaterialTheme.colorScheme.surfaceContainerHigh)
      .clickable(enabled = asset != null) { onOpen(flat) },
  ) {
    if (image != null) {
      Image(image, contentDescription = asset?.name, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
    } else if (thumbnail.failed) {
      // Nothing to show for it, which is different from not yet: the server has no thumbnail.
      Icon(
        Icons.Rounded.BrokenImage,
        contentDescription = null,
        tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
        modifier = Modifier.align(Alignment.Center).size(24.dp),
      )
    }
    if (asset?.isVideo == true) {
      Row(
        Modifier.align(Alignment.TopEnd).padding(4.dp),
        verticalAlignment = Alignment.CenterVertically,
      ) {
        Text(
          formatDuration(asset.durationMs),
          style = MaterialTheme.typography.labelSmall,
          color = Color.White,
        )
        Icon(Icons.Rounded.PlayArrow, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
      }
    }
    if (asset?.isFavorite == true) {
      Icon(
        Icons.Rounded.Favorite,
        contentDescription = null,
        tint = Color.White,
        modifier = Modifier.align(Alignment.BottomStart).padding(4.dp).size(14.dp),
      )
    }
  }
}

/**
 * A fast scroller on the trailing edge: appears while the grid moves, and drags the grid by
 * date. Position maps to the flat index, so dense days take more of the track, as they should.
 */
@Composable
private fun TimelineScrubber(
  state: LazyGridState,
  source: TimelineSource,
  layout: GridLayout,
  bottomPadding: androidx.compose.ui.unit.Dp,
  modifier: Modifier = Modifier,
) {
  val total = source.total
  if (total < 60) return
  var dragging by remember { mutableStateOf(false) }
  var dragFraction by remember { mutableFloatStateOf(0f) }
  var visible by remember { mutableStateOf(false) }
  val scrolling = state.isScrollInProgress
  LaunchedEffect(scrolling, dragging) {
    if (scrolling || dragging) {
      visible = true
    } else {
      delay(1500)
      visible = false
    }
  }
  val firstFlat = layout.flatOf(state.firstVisibleItemIndex)
  val fraction = if (dragging) dragFraction else (firstFlat.toFloat() / total).coerceIn(0f, 1f)
  // Applied on the next measure pass, not as a suspending scroll per event: a scroll that runs
  // inside the gesture re-measures the grid under the finger for every delta.
  LaunchedEffect(dragging) {
    if (!dragging) return@LaunchedEffect
    snapshotFlow { dragFraction }.collectLatest { f ->
      val target = layout.gridIndexOf((f * (total - 1)).toInt())
      state.requestScrollToItem(target)
    }
  }
  val date = source.sections.getOrNull(source.sectionIndex((fraction * (total - 1)).toInt()))?.date
  val alpha by animateFloatAsState(if (visible) 1f else 0f, tween(200), label = "scrubber")

  BoxWithConstraints(modifier.fillMaxHeight().padding(bottom = bottomPadding).graphicsLayer { this.alpha = alpha }) {
    val thumbPx = with(LocalDensity.current) { THUMB_HEIGHT.roundToPx() }
    val track = (constraints.maxHeight - thumbPx).coerceAtLeast(1)
    val y = (fraction * track).roundToInt()
    Row(
      Modifier.offset { androidx.compose.ui.unit.IntOffset(0, y) },
      verticalAlignment = Alignment.CenterVertically,
    ) {
      if (dragging && date != null) {
        Surface(
          shape = RoundedCornerShape(16.dp),
          color = MaterialTheme.colorScheme.surfaceContainerHigh,
          tonalElevation = 3.dp,
          modifier = Modifier.padding(end = 12.dp),
        ) {
          Text(
            monthTitle(date),
            style = MaterialTheme.typography.labelLarge,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
            textAlign = TextAlign.Center,
          )
        }
      }
      Box(
        Modifier
          .width(48.dp)
          .height(THUMB_HEIGHT)
          .padding(end = 4.dp)
          .draggable(
            orientation = Orientation.Vertical,
            state = rememberDraggableState { delta ->
              dragFraction = ((dragFraction * track + delta) / track).coerceIn(0f, 1f)
            },
            onDragStarted = {
              dragFraction = fraction
              dragging = true
            },
            onDragStopped = { dragging = false },
          ),
      ) {
        Box(
          Modifier
            .align(Alignment.CenterEnd)
            .width(6.dp)
            .height(THUMB_HEIGHT)
            .clip(RoundedCornerShape(3.dp))
            .background(MaterialTheme.colorScheme.primary),
        )
      }
    }
  }
}

private val SPACING = 2.dp
private val MIN_TILE = 96.dp
private val THUMB_HEIGHT = 48.dp

private fun localDate(epochMs: Long): LocalDate = Instant.ofEpochMilli(epochMs).atZone(ZoneId.systemDefault()).toLocalDate()

private val dayThisYear = DateTimeFormatter.ofPattern("EEEE, d MMMM")
private val dayOtherYear = DateTimeFormatter.ofPattern("EEE, d MMMM yyyy")

internal fun dayTitle(epochMs: Long?): String {
  if (epochMs == null) return ""
  val date = localDate(epochMs)
  val today = LocalDate.now()
  return when {
    date == today -> "Today"
    date == today.minusDays(1) -> "Yesterday"
    date.year == today.year -> dayThisYear.format(date)
    else -> dayOtherYear.format(date)
  }
}

private fun monthTitle(epochMs: Long): String {
  val date = localDate(epochMs)
  return "${date.month.getDisplayName(TextStyle.SHORT, Locale.getDefault())} ${date.year}"
}

internal fun formatDuration(durationMs: Long?): String {
  val seconds = ((durationMs ?: 0L) / 1000).coerceAtLeast(0)
  val hours = seconds / 3600
  val minutes = (seconds % 3600) / 60
  val rest = seconds % 60
  return if (hours > 0) "%d:%02d:%02d".format(hours, minutes, rest) else "%d:%02d".format(minutes, rest)
}
