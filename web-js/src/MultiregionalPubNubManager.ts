import * as Pubnub from "pubnub"

type MultiregionalPubNubManagerOptions = {
  defaultConfig: Pubnub.PubnubConfig
  backupOrigins: Array<string>
}

const RECONNECTION_TIMEOUT = 60_000
const DIAGNOSIS_TIMEOUT = 10_000
const DIAGNOSIS_RETRIES = 5

export class MultiregionalPubNubManager {
  private instance: Pubnub

  private handleStatus = (statusEvent: Pubnub.StatusEvent) => {
    if (statusEvent.category === "PNNetworkIssuesCategory") {
      this.setupDiagnosis()
    }
  }

  private managerListener: Pubnub.ListenerParameters = {
    status: this.handleStatus,
  }

  public currentBackup: number | null = null

  public get isInFailover() {
    return this.currentBackup !== null
  }

  constructor(private config: MultiregionalPubNubManagerOptions) {
    this.bindInstance(config.defaultConfig)
  }

  private bindInstance(config: Pubnub.PubnubConfig) {
    this.instance = new Pubnub(config)

    this.instance.addListener(this.managerListener)

    for (const listener of this.userListeners) {
      this.instance.addListener(listener)
    }

    for (const subscription of this.subscriptions) {
      this.instance.subscribe(subscription)
    }

    for (const unsubscription of this.unsubscriptions) {
      this.instance.unsubscribe(unsubscription)
    }
  }

  private unbindInstance() {
    if (this.instance) {
      // @ts-ignore
      this.instance.destroy()
      this.instance.removeListener(this.managerListener)

      for (const listener of this.userListeners) {
        this.instance.removeListener(listener)
      }

      this.instance = undefined
    }
  }

  private userListeners: Array<Pubnub.ListenerParameters> = []

  addListener(listener: Pubnub.ListenerParameters) {
    this.userListeners.push(listener)

    this.pubnub.addListener(listener)
  }

  removeListener(listener: Pubnub.ListenerParameters) {
    const index = this.userListeners.indexOf(listener)

    if (index >= 0) {
      this.userListeners.splice(index, 1)
    }

    this.pubnub.removeListener(listener)
  }

  private subscriptions: Array<Pubnub.SubscribeParameters> = []
  private unsubscriptions: Array<Pubnub.UnsubscribeParameters> = []

  subscribe(subscription: Pubnub.SubscribeParameters) {
    this.subscriptions.push(subscription)

    this.pubnub.subscribe(subscription)
  }

  unsubscribe(unsubscription: Pubnub.UnsubscribeParameters) {
    this.unsubscriptions.push(unsubscription)

    this.pubnub.unsubscribe(unsubscription)
  }

  get pubnub() {
    return this.instance
  }

  async failover() {
    if (this.isInFailover) {
      this.currentBackup += 1
    } else {
      this.currentBackup = 0

      this.setupReconnection()
    }

    return this.bindFromBackup()
  }

  private async bindFromBackup() {
    this.unbindInstance()

    const origin = this.config.backupOrigins[this.currentBackup]

    if (origin === undefined) {
      throw new Error(
        "All backup origins are exhausted. Probably the internet is down?"
      )
    }

    const config = { ...this.config.defaultConfig, origin: origin }

    try {
      await this.tryOrigin(origin, config)

      this.bindInstance(config)
    } catch (e) {
      console.log("Backup origin failed: ", origin)

      return this.failover()
    }
  }

  restore() {
    if (this.reconnectionTimer) {
      clearTimeout(this.reconnectionTimer)
    }

    this.unbindInstance()
    this.bindInstance(this.config.defaultConfig)
  }

  private setupDiagnosis = () => {
    this.diagnosisTimer = setTimeout(this.handleDiagnosis, DIAGNOSIS_TIMEOUT)
  }
  private diagnosisRetries = 0
  private diagnosisTimer: number | null = null
  private handleDiagnosis = async () => {
    try {
      await this.tryOrigin(
        this.config.defaultConfig.origin as string,
        this.config.defaultConfig
      )

      clearTimeout(this.diagnosisTimer)
    } catch (e) {
      if (this.diagnosisRetries >= DIAGNOSIS_RETRIES - 1) {
        this.diagnosisRetries = 0
        this.failover()
      } else {
        this.diagnosisRetries += 1
        this.setupDiagnosis()
      }
    }
  }

  private setupReconnection = () => {
    this.reconnectionTimer = setTimeout(
      this.handleReconnection,
      RECONNECTION_TIMEOUT
    )
  }

  private reconnectionTimer: number | null = null
  private handleReconnection = async () => {
    try {
      await this.tryOrigin(
        this.config.defaultConfig.origin as string,
        this.config.defaultConfig
      )

      this.restore()
    } catch (e) {
      this.setupReconnection()
    }
  }

  private tryOrigin = async (origin: string, config: Pubnub.PubnubConfig) => {
    const request = await fetch(
      // TODO: this will require the auth query param for the auth-key so it doesn't 403
      `https://${origin}/v2/subscribe/${config.subscribeKey}/reconnection_test/0`
    )

    await request.json()
  }
}
