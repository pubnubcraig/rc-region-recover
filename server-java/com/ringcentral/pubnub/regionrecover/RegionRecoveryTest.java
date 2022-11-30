package com.ringcentral.pubnub.regionrecover;

import com.github.tomakehurst.wiremock.core.WireMockConfiguration;
import com.github.tomakehurst.wiremock.junit.WireMockRule;
import com.pubnub.api.enums.PNLogVerbosity;
import org.junit.Rule;
import org.junit.Test;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import static com.github.tomakehurst.wiremock.client.WireMock.aResponse;
import static com.github.tomakehurst.wiremock.client.WireMock.get;
import static com.github.tomakehurst.wiremock.client.WireMock.stubFor;
import static com.github.tomakehurst.wiremock.client.WireMock.urlPathEqualTo;
import static com.github.tomakehurst.wiremock.stubbing.Scenario.STARTED;
import static org.junit.Assert.assertTrue;


public class RegionRecoveryTest {
    PNConfiguration configPrimary = new PNConfiguration(new UserId("myUserId"));

    public RegionRecoveryTest() throws PubNubException {
    }

    @Rule
    public WireMockRule wireMockRule = new WireMockRule(WireMockConfiguration.options().dynamicPort());

    String publishResponse = "{\"timetoken\":1234}";

    @Test
    public void test() throws PubNubException, InterruptedException {
        String subKey = "mySubscribeKey";
        String pubKey = "myPublishKey";
        String channel = "ch";
        String message = "msg";
        String scenarioName = "ringcentral";
        String url = "/publish/" + pubKey + "/" + subKey + "/0/" + channel + "/0/%22" + message + "%22";

        stubFor(get(urlPathEqualTo(url)).inScenario(scenarioName)
                .whenScenarioStateIs(STARTED)
                .willReturn(aResponse()
                        .withFixedDelay(15_000)
                        .withBody(publishResponse))
                .willSetStateTo("fail2"));
        stubFor(get(urlPathEqualTo(url)).inScenario(scenarioName)
                .whenScenarioStateIs("fail2")
                .willReturn(aResponse()
                        .withFixedDelay(15_000)
                        .withBody(publishResponse))
                .willSetStateTo("fail3"));
        stubFor(get(urlPathEqualTo(url)).inScenario(scenarioName)
                .whenScenarioStateIs("fail3")
                .willReturn(aResponse()
                        .withFixedDelay(15_000)
                        .withBody(publishResponse))
                .willSetStateTo("fail again"));

        stubFor(get(urlPathEqualTo(url)).inScenario(scenarioName)
                .whenScenarioStateIs("fail again")
                .willReturn(aResponse()
                        .withBody(publishResponse)
                        .withFixedDelay(10_000))
                .willSetStateTo("not fail"));

        stubFor(get(urlPathEqualTo(url)).inScenario(scenarioName)
                .whenScenarioStateIs("not fail")
                .willReturn(aResponse()
                        .withBody(publishResponse))
                .willSetStateTo(STARTED));

        stubFor(get(urlPathEqualTo("/time/0")).inScenario(scenarioName)
                .willReturn(aResponse()
                        .withBody(publishResponse)
                        .withFixedDelay(15_000)));

        stubFor(get(urlPathEqualTo("/time/0")).inScenario(scenarioName)
                .whenScenarioStateIs("not fail")
                .willReturn(aResponse()
                        .withBody(publishResponse)));

        configPrimary.setSubscribeKey("mySubscribeKey");
        configPrimary.setPublishKey("myPublishKey");
        configPrimary.setOrigin(wireMockRule.baseUrl().substring(7));
        configPrimary.setLogVerbosity(PNLogVerbosity.BODY);
        configPrimary.setSecure(false);
        configPrimary.setNonSubscribeRequestTimeout(5);
        configPrimary.setConnectTimeout(3);

        PNConfiguration configBackupOne = new PNConfiguration(new UserId("myUserId1"));
        configBackupOne.setSubscribeKey("mySubscribeKey");
        configBackupOne.setPublishKey("myPublishKey");
        configBackupOne.setOrigin(wireMockRule.baseUrl().substring(7));
        configBackupOne.setLogVerbosity(PNLogVerbosity.BODY);
        configBackupOne.setSecure(false);
        configBackupOne.setNonSubscribeRequestTimeout(5);
        configBackupOne.setConnectTimeout(3);

        PNConfiguration configBackupTwo = new PNConfiguration(new UserId("myUserId2"));
        configBackupTwo.setSubscribeKey("mySubscribeKey");
        configBackupTwo.setPublishKey("myPublishKey");
        configBackupTwo.setOrigin(wireMockRule.baseUrl().substring(7));
        configBackupTwo.setLogVerbosity(PNLogVerbosity.BODY);
        configBackupTwo.setSecure(false);
        configBackupTwo.setNonSubscribeRequestTimeout(5);
        configBackupTwo.setConnectTimeout(3);

        MultiregionalPubNubManager multiregionalPubNubManager = new MultiregionalPubNubManager(configPrimary, configBackupOne, configBackupTwo);

        CountDownLatch latch = new CountDownLatch(1);

        multiregionalPubNubManager.asyncWithFailover(
                pubnub -> pubnub.publish().channel(channel).message(message),
                (result, status) -> {
                    latch.countDown();
                }
        );

        assertTrue(latch.await(100_000, TimeUnit.MILLISECONDS));
    }
}
