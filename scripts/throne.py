from brownie import THRONE, GameOfRisk, Battle, accounts
from scripts.helper_functions import get_account


def deploy():
    account = get_account()

    throne_con = THRONE.deploy(
        {"from": account},
        publish_source=True,
    )

    print(f"Token {throne_con.address} successfully deployed!")


def add_controller():
    account = get_account()

    throne_con = THRONE[-1]
    game_con = GameOfRisk[-1]
    battle_con = Battle[-1]

    add_tx = throne_con.addController(game_con.address, {"from": account})
    add_tx.wait(1)

    add2_tx = throne_con.addController(battle_con.address, {"from": account})
    add2_tx.wait(1)


def main():
    # deploy()
    add_controller()
