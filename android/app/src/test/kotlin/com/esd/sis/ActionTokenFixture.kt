package com.esd.sis

import java.util.Base64

/** A token shaped as the server signs it (`v1.<base64url JSON {u,c,d,a,e}>.<sig>`); the phone cannot check the signature. */
fun fixtureActionToken(vararg actions: String, user: String = "member-a", chat: String = "c-fixture"): String {
    val a = actions.joinToString(",") { "\"$it\"" }
    val json = """{"u":"$user","c":"$chat","d":"${"0".repeat(64)}","a":[$a],"e":4102444800}"""
    return "v1." + Base64.getUrlEncoder().withoutPadding().encodeToString(json.toByteArray()) + ".sig"
}
