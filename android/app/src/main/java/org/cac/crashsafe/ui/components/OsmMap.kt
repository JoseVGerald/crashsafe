package org.cac.crashsafe.ui.components

import android.annotation.SuppressLint
import android.content.res.Resources
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.drawable.BitmapDrawable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.unit.dp
import org.cac.crashsafe.ui.theme.Type
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import org.cac.crashsafe.ui.theme.Brand
import org.osmdroid.events.MapEventsReceiver
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.BoundingBox
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.CustomZoomButtonsController
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.MapEventsOverlay
import org.osmdroid.views.overlay.Marker
import org.osmdroid.views.overlay.Polyline
import org.osmdroid.views.overlay.TilesOverlay

data class MapMarker(val latitude: Double, val longitude: Double, val title: String, val color: Color, val large: Boolean = false)

/**
 * An OpenStreetMap map (the iOS app uses Apple Maps). Tiles are shown dark to match the night theme, with the
 * required "© OpenStreetMap contributors" credit. `onTap` turns taps into dropped pins.
 */
@SuppressLint("ClickableViewAccessibility")
@Composable
fun OsmMap(
    modifier: Modifier = Modifier,
    center: Pair<Double, Double>?,
    zoom: Double = 14.0,
    markers: List<MapMarker> = emptyList(),
    route: List<Pair<Double, Double>>? = null,
    user: Pair<Double, Double>? = null,
    interactive: Boolean = true,
    fitToContent: Boolean = false,
    onTap: ((Double, Double) -> Unit)? = null,
) {
    val state = remember { MapState() }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    Box(modifier) {
    AndroidView(
        modifier = Modifier.matchParentSize(),
        factory = { context ->
            MapView(context).apply {
                state.view = this
                setTileSource(TileSourceFactory.MAPNIK)
                setMultiTouchControls(interactive)
                zoomController.setVisibility(CustomZoomButtonsController.Visibility.NEVER)
                isTilesScaledToDpi = true
                overlayManager.tilesOverlay.setColorFilter(TilesOverlay.INVERT_COLORS)
                overlayManager.tilesOverlay.loadingBackgroundColor = Brand.surface.toArgb()
                minZoomLevel = 3.0
                controller.setZoom(zoom)
                center?.let { controller.setCenter(GeoPoint(it.first, it.second)) }
                if (!interactive) setOnTouchListener { _, _ -> true }
            }
        },
        update = { map ->
            map.overlays.clear()
            if (onTap != null) {
                map.overlays.add(MapEventsOverlay(object : MapEventsReceiver {
                    override fun singleTapConfirmedHelper(p: GeoPoint): Boolean {
                        onTap(p.latitude, p.longitude)
                        return true
                    }

                    override fun longPressHelper(p: GeoPoint): Boolean = false
                }))
            }
            route?.takeIf { it.size >= 2 }?.let { points ->
                map.overlays.add(Polyline(map).apply {
                    setPoints(points.map { GeoPoint(it.first, it.second) })
                    outlinePaint.color = Brand.blueInk.toArgb()
                    outlinePaint.strokeWidth = 6 * Resources.getSystem().displayMetrics.density
                    outlinePaint.strokeCap = Paint.Cap.ROUND
                    outlinePaint.strokeJoin = Paint.Join.ROUND
                })
            }
            for (marker in markers) {
                map.overlays.add(Marker(map).apply {
                    position = GeoPoint(marker.latitude, marker.longitude)
                    title = marker.title
                    icon = dot(map.resources, marker.color, if (marker.large) 26f else 18f)
                    setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                    setOnMarkerClickListener { _, _ -> onTap == null }
                })
            }
            user?.let { here ->
                map.overlays.add(Marker(map).apply {
                    position = GeoPoint(here.first, here.second)
                    title = "You"
                    icon = dot(map.resources, Color(0xFF2F80ED), 16f)
                    setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                    setOnMarkerClickListener { _, _ -> true }
                })
            }
            val points = (route ?: emptyList()) + markers.map { it.latitude to it.longitude } + listOfNotNull(user)
            val key = if (fitToContent) points.hashCode() else center.hashCode()
            if (key != state.appliedKey) {
                state.appliedKey = key
                if (fitToContent && points.size >= 2) {
                    val box = BoundingBox.fromGeoPointsSafe(points.map { GeoPoint(it.first, it.second) })
                    map.post { runCatching { map.zoomToBoundingBox(box.increaseByScale(1.3f), false, 48) } }
                } else {
                    center?.let { map.controller.setCenter(GeoPoint(it.first, it.second)) }
                    map.controller.setZoom(zoom)
                }
            }
            map.invalidate()
        },
        onRelease = { it.onDetach() },
    )
        // OpenStreetMap's license asks for this credit on every map.
        Text("© OpenStreetMap contributors", style = Type.caption2, color = Color.White.copy(alpha = 0.7f),
            modifier = Modifier.align(Alignment.BottomEnd).background(Color.Black.copy(alpha = 0.35f)).padding(horizontal = 4.dp, vertical = 1.dp))
    }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> state.view?.onResume()
                Lifecycle.Event.ON_PAUSE -> state.view?.onPause()
                else -> {}
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
}

private class MapState {
    var appliedKey: Int? = null
    var view: MapView? = null
}

/** A colored dot with a white ring, for markers. */
private fun dot(resources: Resources, color: Color, sizeDp: Float): BitmapDrawable {
    val density = resources.displayMetrics.density
    val size = (sizeDp * density).toInt()
    val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    paint.color = android.graphics.Color.WHITE
    canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)
    paint.color = color.toArgb()
    canvas.drawCircle(size / 2f, size / 2f, size / 2f - 3 * density, paint)
    return BitmapDrawable(resources, bitmap)
}
