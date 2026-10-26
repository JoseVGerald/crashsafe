package org.cac.crashsafe.core

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.cac.crashsafe.core.crash.CrashEvent
import org.cac.crashsafe.core.crash.ImpactAnalyzer
import org.cac.crashsafe.core.driving.CoachingEngine
import org.cac.crashsafe.core.driving.DrivingAdvice
import org.cac.crashsafe.core.driving.DrivingSnapshot
import org.cac.crashsafe.core.driving.RoadEnvironment
import org.cac.crashsafe.core.driving.WeatherCondition
import org.cac.crashsafe.core.driving.WeatherSnapshot
import org.cac.crashsafe.core.pulse.AssistantContext
import org.cac.crashsafe.core.pulse.AssistantIncident
import org.cac.crashsafe.core.pulse.AssistantScenario
import org.cac.crashsafe.core.pulse.LocalEvidenceAssistant
import org.cac.crashsafe.core.pulse.PorterStemmer
import org.cac.crashsafe.core.pulse.PulseKnowledgeIndex
import org.cac.crashsafe.core.pulse.PulseSentenceFilter
import org.cac.crashsafe.core.pulse.PulseTeamAgent
import org.cac.crashsafe.core.pulse.spokenPart
import org.cac.crashsafe.core.report.ImpactReportFacts
import org.cac.crashsafe.core.roads.RoadSegment
import org.cac.crashsafe.core.util.PhoneFormat
import org.cac.crashsafe.core.util.Validation
import org.cac.crashsafe.model.ChatMessage
import org.cac.crashsafe.model.CheckInOutcome
import org.cac.crashsafe.model.CoachingStyle
import org.cac.crashsafe.model.CrashSnapshot
import org.cac.crashsafe.model.DrivingExperience
import org.cac.crashsafe.model.DrivingFeeling
import org.cac.crashsafe.model.PastCrash
import org.cac.crashsafe.model.UsualPassengers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PulseFilterTest {
    @Test fun theTeamsFilterRewritesDosesAndUnconfirmedClaimsAndDropsBannedPhrases() {
        val reply = "I'm right here with you. Calm down. Take 400 mg of ibuprofen. Help is on the way. " +
            "Turn on your hazard lights if you can... Exchange insurance details."
        assertEquals("I'm right here with you. I can't give a medication dose. I don't have confirmation that worked. " +
            "Turn on your hazard lights if you can, Exchange insurance details.", PulseSentenceFilter.spoken(reply, medicationQuestion = false))
        assertEquals(PulseSentenceFilter.Decision.Drop("banned_phrase"), PulseSentenceFilter.filter("You're fine."))
        assertTrue(PulseSentenceFilter.filter("See https://x.y for more").text == null)
        assertEquals(listOf("Take 2.5 mg now.", "Then rest!"), PulseSentenceFilter.sentences("Take 2.5 mg now. Then rest!"))
    }

    @Test fun spokenRepliesLeaveOutSourcesAndCardIDs() {
        assertEquals("Turn on your hazards.", spokenPart("Turn on your hazards. [HAZARDS]\n\nSources:\nWSDOT: https://x"))
    }

    @Test fun signalsFlagSelfHarmAndDosingConservatively() {
        assertEquals(true to false, PulseTeamAgent.signals("I want to die"))
        assertEquals(false to true, PulseTeamAgent.signals("How much Tylenol can my kid take?"))
        assertEquals(false to false, PulseTeamAgent.signals("my car won't start"))
    }
}

class PulseAgentTest {
    private val agent = PulseTeamAgent(Fixtures.asset("pulse/pulse_core.txt"), Fixtures.asset("pulse/pulse_core_mini.txt"),
        Fixtures.asset("pulse/pulse_turn.json"))

    @Test fun turnBlockHasSortedKeysTheModeAndFlags() {
        val turn = agent.turn("I want to die", mode = "standby", connectivity = "online", crash = PulseTeamAgent.crash(null))
        assertTrue(turn.startsWith("[PULSE_TURN]\n{\"app_flags\":{\"medication_question\":false,\"possible_self_harm\":true}"))
        val json = Json.parseToJsonElement(turn.removePrefix("[PULSE_TURN]\n")).jsonObject
        assertEquals("standby", json["mode"]!!.jsonPrimitive.content)
        assertTrue(json["mode_focus"]!!.jsonPrimitive.content.isNotEmpty())
        assertFalse(turn.contains("\\/"))
        val offline = agent.turn("hi", mode = "standby", connectivity = "offline", crash = PulseTeamAgent.crash(null))
        assertTrue(offline.contains("\"offline_focus\""))
    }

    @Test fun modeFollowsTheStageAndIncident() {
        val incident = AssistantIncident.make(CrashEvent(date = 1_000.0, peakG = 6.0, speedDropMPH = 30.0, isSimulated = true,
            impact = ImpactAnalyzer.simulatedReport()))
        assertEquals("crisis_support", PulseTeamAgent.mode("active", incident))
        assertEquals("aftermath", PulseTeamAgent.mode("followup", incident))
        assertEquals("standby", PulseTeamAgent.mode("active", null))
        val crash = PulseTeamAgent.crash(incident, now = 1_060.0)
        assertEquals("moderate", crash["severity"]!!.jsonPrimitive.content)
        assertEquals(60, crash["seconds_since_crash"]!!.jsonPrimitive.content.toInt())
    }

    @Test fun messagesStartWithCoreAndTurnAndStayInBudget() {
        val history = (0 until 60).map { ChatMessage(if (it % 2 == 0) ChatMessage.Role.user else ChatMessage.Role.assistant, "word ".repeat(200)) }
        val messages = agent.messages(history, turn = "[PULSE_TURN]\n{}", knowledge = "[PULSE_KNOWLEDGE]\nnote")
        assertEquals(agent.core, messages[0]["content"]!!.jsonPrimitive.content)
        assertEquals("user", messages[2]["role"]!!.jsonPrimitive.content)
        assertTrue(messages.size < 40)
    }
}

class PulseKnowledgeTest {
    private val index = PulseKnowledgeIndex(Fixtures.asset("pulse/pulse_knowledge.json"))

    @Test fun porterStemsAsFts5() {
        assertEquals("caress", PorterStemmer.stem("caresses"))
        assertEquals("poni", PorterStemmer.stem("ponies"))
        assertEquals("relat", PorterStemmer.stem("relational"))
        assertEquals("hope", PorterStemmer.stem("hoping"))
        assertEquals("gener", PorterStemmer.stem("generalization"))
        assertEquals("is", PorterStemmer.stem("is"))
    }

    @Test fun findsTheTeamsNotesForAQuestion() {
        assertEquals(108, index.count)
        val result = index.search("My hands are shaking and I feel sick, is this normal?", mode = "standby", connectivity = "online")
        assertTrue(result.text.startsWith("[PULSE_KNOWLEDGE]\n[NOTE "))
        assertTrue(result.ids.isNotEmpty() && result.ids.size <= 12)
        assertEquals("", index.search("anything", mode = "crash_check", connectivity = "online").text)
        assertEquals("", index.search("shaking", mode = "standby", connectivity = "offline").text)
    }
}

class LocalAssistantTest {
    private val context = AssistantContext(userName = "Test", isOnline = true, scenario = AssistantScenario.General,
        carDescription = "", insurer = "", medicalNotes = "", familyContactNames = emptyList(), assistanceStage = "followup")

    @Test fun emergenciesAnswerFirstAndHistoricalOnesDont() {
        assertTrue(LocalEvidenceAssistant.emergencyReply("the car is on fire")!!.startsWith("Call 911"))
        assertNull(LocalEvidenceAssistant.emergencyReply("last week my car was on fire"))
        assertNull(LocalEvidenceAssistant.emergencyReply("nobody is unconscious"))
    }

    @Test fun cardsAnswerWithSources() = runBlocking {
        val reply = LocalEvidenceAssistant().reply(listOf(ChatMessage(ChatMessage.Role.user, "What photos should I take for my insurance claim?")), context)
        assertTrue(reply.contains("[DOCUMENT]") || reply.contains("[CLAIM_NOTICE]"))
        assertTrue(reply.contains("Sources:\n"))
    }
}

class CoachingTest {
    private fun input(speed: Double, limit: Double?, style: CoachingStyle = CoachingStyle.logical, segment: RoadSegment? = null) =
        CoachingEngine.Input(
            snapshot = DrivingSnapshot(speedMPH = speed, speedLimitMPH = limit, roadSegment = segment, environment = RoadEnvironment.city),
            advice = DrivingAdvice.make(null, isNight = false), weather = null, isNight = false, style = style,
            experience = DrivingExperience.newDriver, lovedOne = "your mom")

    @Test fun speedingSpeaksWithTheImpactSpeed() {
        val message = CoachingEngine.message(input(42.0, 30.0))
        assertEquals("Slow to 30 mph", message.title)
        assertTrue(message.speaksAloud)
        assertTrue(message.body.startsWith("You're doing 42 in a 30 on a city street. Imagine a child running out"))
        val heart = CoachingEngine.message(input(42.0, 30.0, CoachingStyle.emotional))
        assertTrue(heart.body.startsWith("Your mom is waiting for you to get home."))
    }

    @Test fun residentialStreetsGetACautionOnce() {
        val message = CoachingEngine.message(input(20.0, 25.0, segment = RoadSegment.residential))
        assertEquals("Residential area: be extra careful", message.title)
        assertEquals(300.0, message.repeatAfter, 0.0)
    }

    @Test fun stoppingDistanceMath() {
        assertEquals(135, CoachingEngine.stoppingDistanceFeet(35.0, 0.7))
        assertEquals(0, CoachingEngine.impactSpeedMPH(25.0, 200.0, 0.7))
        assertTrue(CoachingEngine.pedestrianRisk(42.0).contains("1 in 2"))
    }

    @Test fun weatherAdviceSlowsForRainAtNight() {
        val advice = DrivingAdvice.make(WeatherSnapshot(48.0, WeatherCondition.rain, 9.0, 4.0, isDay = false), isNight = true)
        assertEquals("Wet roads at night", advice.headline)
        assertEquals(6, advice.followingSeconds)
        assertEquals(20, advice.speedReductionPercent)
    }
}

class AboutYouAndReportTest {
    @Test fun aboutYouPicksTheCoachingStyleWithReasons() {
        val (style, reasons) = CoachingStyle.recommended(DrivingExperience.experienced, UsualPassengers.kids, DrivingFeeling.nervous, PastCrash.none, null)
        assertEquals(CoachingStyle.emotional, style)
        assertEquals(listOf("kids ride with you", "driving makes you nervous"), reasons)
        assertEquals(CoachingStyle.logical, CoachingStyle.recommended(DrivingExperience.learner, null, null, null, null).first)
    }

    @Test fun officialReportStatesFactsWithoutFault() {
        val snapshot = CrashSnapshot(date = 1_790_000_000.0, peakG = 6.2, impact = ImpactAnalyzer.simulatedReport(),
            latitude = 45.5, longitude = -122.6, street = "SW Main St", place = "Portland, OR", weather = "Rain, 48°F", isSimulated = true)
        val facts = ImpactReportFacts(snapshot = snapshot, outcome = CheckInOutcome.ok, driverName = "Jose", vehicle = "2019 Toyota Camry",
            insurer = "State Farm", policyNumber = "SF-1", claimsPhone = "(800) 732-5246")
        val text = facts.officialText
        assertTrue(text.startsWith("COLLISION FACTS, RECORDED BY PHONE (TEST, SIMULATED DATA)"))
        assertTrue(text.contains("Location: SW Main St, Portland, OR (45.50000, -122.60000)"))
        assertTrue(text.contains("Driver check-in: driver answered \"I'm okay\""))
        assertFalse(text.lowercase().contains("fault") && !text.contains("do not show fault"))
    }

    @Test fun phoneFormattingAndValidation() {
        assertEquals("(206) 555-0100", PhoneFormat.display("2065550100"))
        assertEquals("(206) 555-0100", PhoneFormat.display("+1 206 555 0100"))
        assertEquals("+44 20 7946 0958", PhoneFormat.display("+44 20 7946 0958"))
        assertEquals("Enter a valid email address.", Validation.email("jose@"))
        assertNull(Validation.email("jose@example.com"))
        assertEquals(4, Validation.passwordScore("Correct-horse-9"))
    }
}
