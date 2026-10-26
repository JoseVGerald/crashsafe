@file:Suppress("DEPRECATION")

package org.cac.crashsafe.ui.theme

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.automirrored.filled.DirectionsBike
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.StarOutline
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * The SF Symbols the iOS app uses, as Material icons. Models keep the symbol names (so both apps share them)
 * and the UI resolves them here.
 */
fun sf(name: String?): ImageVector = when (name) {
    "antenna.radiowaves.left.and.right.slash" -> Icons.Filled.SignalCellularOff
    "arrow.counterclockwise" -> Icons.Filled.RestartAlt
    "arrow.down.circle" -> Icons.Filled.Download
    "arrow.down.to.line" -> Icons.Filled.VerticalAlignBottom
    "arrow.triangle.turn.up.right.circle.fill" -> Icons.Filled.Directions
    "arrow.up" -> Icons.Filled.ArrowUpward
    "arrow.up.arrow.down" -> Icons.Filled.SwapVert
    "bell.badge.fill" -> Icons.Filled.NotificationsActive
    "bicycle" -> Icons.AutoMirrored.Filled.DirectionsBike
    "bolt.car.fill" -> Icons.Filled.ElectricCar
    "bolt.fill" -> Icons.Filled.Bolt
    "briefcase.fill" -> Icons.Filled.Work
    "bubble.left.and.bubble.right.fill" -> Icons.Filled.Forum
    "bubble.left.and.text.bubble.right" -> Icons.AutoMirrored.Filled.Chat
    "building.2.fill" -> Icons.Filled.LocationCity
    "building.columns", "building.columns.fill" -> Icons.Filled.AccountBalance
    "bus.fill" -> Icons.Filled.DirectionsBus
    "calendar" -> Icons.Filled.CalendarMonth
    "calendar.badge.clock" -> Icons.Filled.Event
    "camera.fill" -> Icons.Filled.PhotoCamera
    "car.fill", "car.side.fill" -> Icons.Filled.DirectionsCar
    "car.rear.and.tire.marks" -> Icons.Filled.SocialDistance
    "car.rear.fill" -> Icons.Filled.DirectionsCarFilled
    "car.side.rear.and.collision.and.car.side.front" -> Icons.Filled.CarCrash
    "cart.fill" -> Icons.Filled.ShoppingCart
    "chart.bar.xaxis" -> Icons.Filled.BarChart
    "checkmark" -> Icons.Filled.Check
    "checkmark.circle" -> Icons.Outlined.CheckCircle
    "checkmark.circle.fill" -> Icons.Filled.CheckCircle
    "checkmark.icloud.fill" -> Icons.Filled.CloudDone
    "checkmark.message.fill" -> Icons.Filled.MarkChatRead
    "checkmark.shield.fill" -> Icons.Filled.VerifiedUser
    "checklist" -> Icons.Filled.Checklist
    "chevron.left" -> Icons.Filled.ChevronLeft
    "chevron.right" -> Icons.Filled.ChevronRight
    "chevron.up.chevron.down" -> Icons.Filled.UnfoldMore
    "circle" -> Icons.Filled.RadioButtonUnchecked
    "circle.circle.fill" -> Icons.Filled.RadioButtonChecked
    "circle.fill" -> Icons.Filled.Circle
    "clock.badge.exclamationmark" -> Icons.Filled.Schedule
    "cloud.bolt.rain.fill" -> Icons.Filled.Thunderstorm
    "cloud.drizzle.fill" -> Icons.Filled.Grain
    "cloud.fill" -> Icons.Filled.Cloud
    "cloud.fog.fill" -> Icons.Filled.Dehaze
    "cloud.heavyrain.fill" -> Icons.Filled.Umbrella
    "cloud.moon.fill" -> Icons.Filled.NightsStay
    "cloud.rain.fill" -> Icons.Filled.WaterDrop
    "cloud.sleet.fill", "cloud.snow.fill", "snowflake" -> Icons.Filled.AcUnit
    "cloud.sun.fill" -> Icons.Filled.WbCloudy
    "cross.case.fill" -> Icons.Filled.MedicalServices
    "cross.fill" -> Icons.Filled.LocalHospital
    "doc.on.doc" -> Icons.Filled.ContentCopy
    "doc.text.fill" -> Icons.Filled.Description
    "dot.radiowaves.left.and.right", "sensor.fill" -> Icons.Filled.Sensors
    "drop.fill" -> Icons.Filled.WaterDrop
    "ellipsis" -> Icons.Filled.MoreHoriz
    "envelope.badge.fill" -> Icons.Filled.MarkEmailUnread
    "envelope.fill" -> Icons.Filled.Email
    "exclamationmark.bubble.fill" -> Icons.Filled.ReportProblem
    "exclamationmark.circle.fill" -> Icons.Filled.Error
    "exclamationmark.octagon.fill" -> Icons.Filled.Report
    "exclamationmark.triangle", "exclamationmark.triangle.fill" -> Icons.Filled.Warning
    "eye.fill" -> Icons.Filled.Visibility
    "eye.slash" -> Icons.Filled.VisibilityOff
    "face.smiling" -> Icons.Filled.SentimentSatisfied
    "figure.and.child.holdinghands" -> Icons.Filled.FamilyRestroom
    "figure.run" -> Icons.AutoMirrored.Filled.DirectionsRun
    "figure.stand" -> Icons.Filled.Accessibility
    "figure.walk", "figure.walk.motion" -> Icons.AutoMirrored.Filled.DirectionsWalk
    "flag.checkered" -> Icons.Filled.SportsScore
    "gauge.with.dots.needle.33percent", "gauge.with.dots.needle.50percent" -> Icons.Filled.Speed
    "graduationcap.fill" -> Icons.Filled.School
    "gyroscope" -> Icons.Filled.ScreenRotation
    "hammer.fill" -> Icons.Filled.Build
    "hand.raised.fill" -> Icons.Filled.PanTool
    "hand.tap.fill" -> Icons.Filled.TouchApp
    "hand.thumbsup.fill" -> Icons.Filled.ThumbUp
    "headlight.low.beam.fill" -> Icons.Filled.Highlight
    "heart.fill" -> Icons.Filled.Favorite
    "heart.text.square.fill", "waveform.path.ecg" -> Icons.Filled.MonitorHeart
    "hourglass" -> Icons.Filled.HourglassEmpty
    "house.fill" -> Icons.Filled.Home
    "icloud.slash" -> Icons.Filled.CloudOff
    "info.circle", "info.circle.fill" -> Icons.Filled.Info
    "iphone" -> Icons.Filled.Smartphone
    "iphone.slash" -> Icons.Filled.MobileOff
    "leaf.fill" -> Icons.Filled.Eco
    "location.circle.fill" -> Icons.Filled.MyLocation
    "location.fill" -> Icons.Filled.NearMe
    "lock.fill" -> Icons.Filled.Lock
    "lock.iphone" -> Icons.Filled.ScreenLockPortrait
    "lock.rotation" -> Icons.Filled.LockReset
    "lock.shield.fill", "shield.fill" -> Icons.Filled.Shield
    "magnifyingglass" -> Icons.Filled.Search
    "map", "map.fill" -> Icons.Filled.Map
    "mappin.and.ellipse" -> Icons.Filled.PinDrop
    "mappin.circle.fill" -> Icons.Filled.Place
    "message" -> Icons.Filled.Sms
    "mic.fill" -> Icons.Filled.Mic
    "mic.slash.fill" -> Icons.Filled.MicOff
    "minus.circle.fill" -> Icons.Filled.RemoveCircle
    "moon.fill" -> Icons.Filled.DarkMode
    "moon.stars.fill" -> Icons.Filled.NightsStay
    "motorcycle" -> Icons.Filled.TwoWheeler
    "number" -> Icons.Filled.Tag
    "pause.circle" -> Icons.Filled.PauseCircle
    "pencil" -> Icons.Filled.Edit
    "person", "person.fill" -> Icons.Filled.Person
    "person.2.fill" -> Icons.Filled.People
    "person.crop.circle.badge.plus" -> Icons.Filled.PersonAdd
    "person.crop.circle.fill" -> Icons.Filled.AccountCircle
    "phone.badge.plus" -> Icons.Filled.AddIcCall
    "phone.circle.fill" -> Icons.Filled.Call
    "phone.down.fill" -> Icons.Filled.CallEnd
    "phone.fill" -> Icons.Filled.Phone
    "photo" -> Icons.Filled.Photo
    "play.circle", "play.circle.fill" -> Icons.Filled.PlayCircle
    "play.fill" -> Icons.Filled.PlayArrow
    "plus", "plus.circle", "plus.circle.fill" -> Icons.Filled.AddCircle
    "questionmark.bubble.fill" -> Icons.Filled.QuestionAnswer
    "questionmark.circle" -> Icons.Filled.QuestionMark
    "record.circle" -> Icons.Filled.FiberManualRecord
    "road.lanes" -> Icons.Filled.AddRoad
    "shield.lefthalf.filled" -> Icons.Filled.LocalPolice
    "sparkles" -> Icons.Filled.AutoAwesome
    "speaker.slash.fill" -> Icons.Filled.VolumeOff
    "speaker.wave.2.fill", "speaker.wave.3.fill" -> Icons.Filled.VolumeUp
    "square.and.arrow.up" -> Icons.Filled.Share
    "star" -> Icons.Outlined.StarOutline
    "star.fill" -> Icons.Filled.Star
    "staroflife.fill" -> Icons.Filled.HealthAndSafety
    "steeringwheel" -> Icons.Filled.Navigation
    "stop.fill" -> Icons.Filled.Stop
    "sun.max.fill" -> Icons.Filled.WbSunny
    "suv.side.fill" -> Icons.Filled.AirportShuttle
    "tram.fill" -> Icons.Filled.Tram
    "tram.tunnel.fill" -> Icons.Filled.Subway
    "trash" -> Icons.Filled.Delete
    "tree.fill" -> Icons.Filled.Forest
    "truck.box.fill", "truck.pickup.side.fill" -> Icons.Filled.LocalShipping
    "waveform", "waveform.circle.fill" -> Icons.Filled.GraphicEq
    "waveform.badge.mic" -> Icons.Filled.RecordVoiceOver
    "waveform.path" -> Icons.Filled.Timeline
    "wifi" -> Icons.Filled.Wifi
    "wifi.slash" -> Icons.Filled.WifiOff
    "wind" -> Icons.Filled.Air
    "xmark" -> Icons.Filled.Close
    "cloud.fill.online" -> Icons.Filled.Cloud
    else -> Icons.Filled.Circle
}
