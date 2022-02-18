from brownie import THRONE, GameOfRisk, Battle, Traits3, accounts
from scripts.helper_functions import get_account


def deploy():
    account = get_account()

    traits_con = Traits3.deploy(
        {"from": account},
        publish_source=True,
    )

    print(f"Token {traits_con.address} successfully deployed!")


def set_game():
    account = get_account()

    traits_con = Traits3[-1]
    game_con = GameOfRisk[-1]

    add_tx = traits_con.setGame(game_con.address, {"from": account})
    add_tx.wait(1)


def main():
    # deploy()
    set_game()
