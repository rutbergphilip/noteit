/** How an action reports a failure the client branches on: `serverError` from middleware, `businessError` from `fail()`. */
export interface ActionFailure {
  code: string;
  message: string;
}
