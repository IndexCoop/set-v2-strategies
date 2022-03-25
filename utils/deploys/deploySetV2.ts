import { Signer } from "ethers";
import {
  Address
} from "../types";

import { SetToken } from "@setprotocol/set-protocol-v2/typechain/SetToken";
import { SetToken__factory } from "@setprotocol/set-protocol-v2/dist/typechain/factories/SetToken__factory";
import { DebtIssuanceModule } from "@setprotocol/set-protocol-v2/typechain/DebtIssuanceModule";
import { DebtIssuanceModule__factory } from "@setprotocol/set-protocol-v2/dist/typechain/factories/DebtIssuanceModule__factory";
import { DebtIssuanceModuleV2 } from "@setprotocol/set-protocol-v2/typechain/DebtIssuanceModuleV2";
import { DebtIssuanceModuleV2__factory } from "@setprotocol/set-protocol-v2/dist/typechain/factories/DebtIssuanceModuleV2__factory";

export default class DeploySetV2 {
  private _deployerSigner: Signer;

  constructor(deployerSigner: Signer) {
    this._deployerSigner = deployerSigner;
  }

  public async deployDebtIssuanceModule(
    controller: Address,
  ): Promise<DebtIssuanceModule> {
    return await new DebtIssuanceModule__factory(this._deployerSigner).deploy(
      controller,
    );
  }

  public async deployDebtIssuanceModuleV2(
    controller: Address,
  ): Promise<DebtIssuanceModuleV2> {
    return await new DebtIssuanceModuleV2__factory(this._deployerSigner).deploy(
      controller,
    );
  }

  /* GETTERS */

  public async getSetToken(setTokenAddress: Address): Promise<SetToken> {
    return await new SetToken__factory(this._deployerSigner).attach(setTokenAddress);
  }
}
