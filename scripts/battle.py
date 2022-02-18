from brownie import THRONE, GameOfRisk, Battle, Traits3, accounts
from scripts.helper_functions import get_account


def deploy():
    account = get_account()

    throne_con = THRONE[-1]
    game_con = GameOfRisk[-1]

    battle_con = Battle.deploy(
        game_con,
        throne_con,
        {"from": account},
        publish_source=True,
    )


def set_approval_for():
    account = get_account()

    game_con = GameOfRisk[-1]
    battle_con = Battle[-1]

    add_tx = game_con.setApprovalForAll(battle_con.address, True, {"from": account})
    add_tx.wait(1)


def add_to_battle():
    account = get_account()

    battle_con = Battle[-1]

    add_tx = battle_con.addManyToBattleAndPack(account, [0], {"from": account})
    add_tx.wait(1)


def claim_from_battle():
    account = get_account()

    battle_con = Battle[-1]

    add_tx = battle_con.claimManyFromBattleAndPack([1], True, {"from": account})
    add_tx.wait(1)


def main():
    # deploy()
    # set_approval_for()
    # add_to_battle()
    claim_from_battle()
